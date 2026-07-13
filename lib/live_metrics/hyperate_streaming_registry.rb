# frozen_string_literal: true

require "json"

module ::LiveMetrics
  class HypeRateStreamingRegistry
    LEADER_KEY = "live_metrics:hyperate_streaming:leader:v1"
    SESSION_KEY_PREFIX = "live_metrics:hyperate_streaming:session:v1"
    HEALTH_KEY = "live_metrics:hyperate_streaming:health:v1"
    LEADER_TTL_SECONDS = 15
    SESSION_TTL_SECONDS = 30
    HEALTH_TTL_SECONDS = 15

    COMPARE_AND_EXPIRE_SCRIPT = <<~LUA.freeze
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("EXPIRE", KEYS[1], ARGV[2])
      end
      return 0
    LUA

    COMPARE_AND_DELETE_SCRIPT = <<~LUA.freeze
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
      end
      return 0
    LUA

    class << self
      def acquire_or_renew_leader(token)
        return false if token.blank?

        created = redis.set(LEADER_KEY, token.to_s, nx: true, ex: LEADER_TTL_SECONDS)
        return true if created.present?

        compare_and_expire(LEADER_KEY, token, LEADER_TTL_SECONDS)
      rescue => e
        log_failure("leader acquire", nil, e)
        false
      end

      def release_leader(token)
        compare_and_delete(LEADER_KEY, token)
      rescue => e
        log_failure("leader release", nil, e)
        false
      end

      def activate_session(account_or_id, token)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || token.blank?

        redis.set(session_key(account_id), token.to_s, ex: SESSION_TTL_SECONDS).present?
      rescue => e
        log_failure("session activate", account_id, e)
        false
      end

      def session_current?(account_or_id, token)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || token.blank?

        redis.get(session_key(account_id)).to_s == token.to_s
      rescue
        false
      end

      def touch_session(account_or_id, token)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || token.blank?

        compare_and_expire(session_key(account_id), token, SESSION_TTL_SECONDS)
      rescue => e
        log_failure("session touch", account_id, e)
        false
      end

      def release_session(account_or_id, token)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || token.blank?

        compare_and_delete(session_key(account_id), token)
      rescue => e
        log_failure("session release", account_id, e)
        false
      end

      def invalidate_session(account_or_id)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank?

        redis.del(session_key(account_id))
        true
      rescue => e
        log_failure("session invalidate", account_id, e)
        false
      end

      def write_state_if_current(account, payload, token)
        return nil if account.blank? || account.id.blank? || token.blank?

        ::LiveMetrics::CurrentStateStore.write_if(
          account,
          payload,
          guard_key: session_key(account.id),
          guard_value: token,
        )
      rescue => e
        log_failure("state write", account&.id, e)
        nil
      end

      def publish_health(payload)
        sanitized = {
          v: 1,
          pid: Process.pid,
          updated_at_ms: (Time.now.to_f * 1000).to_i,
          sessions: payload[:sessions].to_i,
          connected: payload[:connected].to_i,
          reconnecting: payload[:reconnecting].to_i,
          limit: payload[:limit].to_i,
        }

        redis.set(HEALTH_KEY, JSON.generate(sanitized), ex: HEALTH_TTL_SECONDS)
      rescue => e
        log_failure("health write", nil, e)
        nil
      end

      def clear_health
        redis.del(HEALTH_KEY)
      rescue
        nil
      end

      def session_key(account_or_id)
        account_id = account_id_for(account_or_id)
        "#{SESSION_KEY_PREFIX}:#{account_id}"
      end

      private

      def compare_and_expire(key, token, ttl)
        redis.eval(
          COMPARE_AND_EXPIRE_SCRIPT,
          keys: [namespaced_key(key)],
          argv: [token.to_s, ttl.to_i.to_s],
        ).to_i == 1
      end

      def compare_and_delete(key, token)
        redis.eval(
          COMPARE_AND_DELETE_SCRIPT,
          keys: [namespaced_key(key)],
          argv: [token.to_s],
        ).to_i == 1
      end

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

      def log_failure(operation, account_id, error)
        suffix = account_id.present? ? " account_id=#{account_id}" : ""
        Rails.logger.warn(
          "[live_metrics] HypeRate streaming registry #{operation} failed#{suffix} error=#{error.class}: #{error.message}",
        )
      end
    end
  end
end
