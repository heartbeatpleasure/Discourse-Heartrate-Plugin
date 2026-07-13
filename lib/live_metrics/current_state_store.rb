# frozen_string_literal: true

require "json"

module ::LiveMetrics
  class CurrentStateStore
    VERSION = 1
    KEY_PREFIX = "live_metrics:current_state:v1"
    MIN_TTL_SECONDS = 30
    MAX_TTL_SECONDS = 120
    TTL_GRACE_SECONDS = 15
    VALID_ERROR_CODES = %w[no_data unauthorized unavailable].freeze

    GUARDED_WRITE_SCRIPT = <<~LUA.freeze
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        redis.call("SET", KEYS[2], ARGV[2], "EX", ARGV[3])
        return 1
      end
      return 0
    LUA

    class << self
      def read(account_or_id)
        account_id = account_id_for(account_or_id)
        return nil if account_id.blank?

        parse_state(redis.get(key(account_id)))
      rescue => e
        log_failure("read", account_id, e)
        nil
      end

      def read_many(accounts)
        accounts = Array(accounts).compact
        return {} if accounts.blank?

        ids = accounts.map { |account| account_id_for(account) }.compact.uniq
        return {} if ids.blank?

        values = redis.mget(*ids.map { |id| key(id) })

        ids.each_with_index.each_with_object({}) do |(account_id, index), result|
          state = parse_state(values[index])
          result[account_id] = state if state.present?
        end
      rescue => e
        log_failure("read_many", nil, e)
        {}
      end

      def write(account, live_payload)
        return nil if account.blank? || account.id.blank?

        payload = normalized_storage_payload(account, live_payload)
        serialized = JSON.generate(payload)
        written =
          redis.set(
            key(account.id),
            serialized,
            ex: expiry_seconds_for(payload),
          )
        written.present? ? parse_state(serialized) : nil
      rescue => e
        log_failure("write", account&.id, e)
        nil
      end

      def write_if(account, live_payload, guard_key:, guard_value:)
        return nil if account.blank? || account.id.blank?
        return nil if guard_key.blank? || guard_value.blank?

        payload = normalized_storage_payload(account, live_payload)
        serialized = JSON.generate(payload)
        written =
          redis.eval(
            GUARDED_WRITE_SCRIPT,
            keys: [namespaced_key(guard_key), namespaced_key(key(account.id))],
            argv: [guard_value.to_s, serialized, expiry_seconds_for(payload).to_s],
          ).to_i == 1

        written ? parse_state(serialized) : nil
      rescue => e
        log_failure("guarded write", account&.id, e)
        nil
      end

      def delete(account_or_id)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank?

        redis.del(key(account_id))
        true
      rescue => e
        log_failure("delete", account_id, e)
        false
      end

      def delete_many(accounts_or_ids)
        ids = Array(accounts_or_ids).map { |value| account_id_for(value) }.compact.uniq
        return 0 if ids.blank?

        redis.del(*ids.map { |id| key(id) })
      rescue => e
        log_failure("delete_many", nil, e)
        0
      end

      def ttl_seconds
        stale = SiteSetting.live_metrics_stale_threshold_seconds.to_i
        stale = 0 if stale.negative?
        [[stale + TTL_GRACE_SECONDS, MIN_TTL_SECONDS].max, MAX_TTL_SECONDS].min
      end

      def key(account_or_id)
        account_id = account_id_for(account_or_id)
        "#{KEY_PREFIX}:#{account_id}"
      end

      def state_with_reading?(state)
        state.present? && state[:heart_rate].to_i.positive? && state[:measured_at_ms].to_i.positive?
      end

      private

      def redis
        Discourse.redis
      end

      def namespaced_key(logical_key)
        redis.namespace_key(logical_key.to_s)
      end

      def account_id_for(account_or_id)
        value = account_or_id.respond_to?(:id) ? account_or_id.id : account_or_id
        id = value.to_i
        id.positive? ? id : nil
      end

      def normalized_storage_payload(account, live_payload)
        live = (live_payload || {}).with_indifferent_access
        now_ms = current_time_ms
        heart_rate = normalize_heart_rate(live[:heart_rate])
        measured_at_ms = normalize_measured_at_ms(live)
        reading_age_ms = measured_at_ms.present? ? [now_ms - measured_at_ms, 0].max : nil
        within_hard_retention =
          reading_age_ms.present? && reading_age_ms < (ttl_seconds * 1000)
        has_reading =
          heart_rate.present? && measured_at_ms.present? && within_hard_retention
        error_code =
          if has_reading
            nil
          elsif heart_rate.present? && measured_at_ms.present?
            "no_data"
          else
            normalize_error_code(live[:status])
          end

        {
          "v" => VERSION,
          "provider" => account.provider.to_s,
          "status" => has_reading ? "live" : error_code,
          "heart_rate" => has_reading ? heart_rate : nil,
          "measured_at_ms" => has_reading ? measured_at_ms : nil,
          "received_at_ms" => now_ms,
          "error_code" => error_code,
        }
      end

      def expiry_seconds_for(payload)
        measured_at_ms = positive_integer(payload["measured_at_ms"])
        return ttl_seconds if measured_at_ms.blank?

        age_ms = [current_time_ms - measured_at_ms, 0].max
        remaining_ms = (ttl_seconds * 1000) - age_ms
        return 1 if remaining_ms <= 0

        [(remaining_ms / 1000.0).ceil, ttl_seconds].min
      end

      def parse_state(raw)
        return nil if raw.blank?

        payload = JSON.parse(raw.to_s)
        return nil unless payload["v"].to_i == VERSION

        provider = payload["provider"].to_s
        heart_rate = normalize_heart_rate(payload["heart_rate"])
        measured_at_ms = positive_integer(payload["measured_at_ms"])
        received_at_ms = positive_integer(payload["received_at_ms"])

        expired_reading = false
        if heart_rate.present? && measured_at_ms.present?
          age_seconds = [(current_time_ms - measured_at_ms) / 1000, 0].max

          if age_seconds < ttl_seconds
            return {
              status: status_for_age(age_seconds),
              heart_rate: heart_rate,
              measured_at: Time.zone.at(measured_at_ms / 1000.0).iso8601,
              measured_at_ms: measured_at_ms,
              received_at_ms: received_at_ms,
              age_seconds: age_seconds,
              provider: provider,
              error_code: nil,
            }
          end

          expired_reading = true
        end

        error_code =
          if expired_reading
            "no_data"
          else
            normalize_error_code(payload["error_code"].presence || payload["status"])
          end

        {
          status: error_code,
          heart_rate: nil,
          measured_at: nil,
          measured_at_ms: nil,
          received_at_ms: received_at_ms,
          age_seconds: nil,
          provider: provider,
          error_code: error_code,
        }
      rescue JSON::ParserError, TypeError, ArgumentError
        nil
      end

      def status_for_age(age_seconds)
        live_threshold = SiteSetting.live_metrics_live_threshold_seconds.to_i
        stale_threshold = SiteSetting.live_metrics_stale_threshold_seconds.to_i
        live_threshold = 0 if live_threshold.negative?
        stale_threshold = [stale_threshold, live_threshold].max

        if age_seconds <= live_threshold
          "live"
        elsif age_seconds <= stale_threshold
          "delayed"
        else
          "stale"
        end
      end

      def normalize_heart_rate(value)
        heart_rate = value.to_i
        heart_rate.positive? && heart_rate < 260 ? heart_rate : nil
      end

      def normalize_measured_at_ms(live)
        measured_at_ms = positive_integer(live[:measured_at_ms])
        return measured_at_ms if measured_at_ms.present?

        if live[:measured_at].present?
          parsed = Time.zone.parse(live[:measured_at].to_s)
          return (parsed.to_f * 1000).to_i if parsed.present?
        end

        if live[:age_seconds].present?
          age_seconds = [live[:age_seconds].to_i, 0].max
          return current_time_ms - (age_seconds * 1000)
        end

        nil
      rescue ArgumentError, TypeError
        nil
      end

      def normalize_error_code(value)
        code = value.to_s
        VALID_ERROR_CODES.include?(code) ? code : "unavailable"
      end

      def positive_integer(value)
        integer = value.to_i
        integer.positive? ? integer : nil
      end

      def current_time_ms
        (Time.zone.now.to_f * 1000).to_i
      end

      def log_failure(operation, account_id, error)
        suffix = account_id.present? ? " account_id=#{account_id}" : ""
        Rails.logger.warn(
          "[live_metrics] current state #{operation} failed#{suffix} error=#{error.class}: #{error.message}",
        )
      end
    end
  end
end
