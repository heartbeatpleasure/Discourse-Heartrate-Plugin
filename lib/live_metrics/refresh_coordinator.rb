# frozen_string_literal: true

require "securerandom"

module ::LiveMetrics
  class RefreshCoordinator
    LOOP_KEY_PREFIX = "live_metrics:refresh_loop:v1"
    FETCH_LOCK_KEY_PREFIX = "live_metrics:fetch_lock:v1"
    LOOP_TTL_SECONDS = 120
    FETCH_LOCK_TTL_SECONDS = 120

    RELEASE_LOCK_SCRIPT = <<~LUA.freeze
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
      end
      return 0
    LUA

    TOUCH_GENERATION_SCRIPT = <<~LUA.freeze
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("EXPIRE", KEYS[1], ARGV[2])
      end
      return 0
    LUA

    class << self
      def async_enabled?
        SiteSetting.live_metrics_enabled && SiteSetting.live_metrics_async_current_readings_enabled
      rescue
        false
      end

      def hyperate_streaming_enabled?
        async_enabled? &&
          SiteSetting.live_metrics_hyperate_enabled &&
          SiteSetting.live_metrics_hyperate_streaming_enabled &&
          ::LiveMetrics::HypeRateClient.configured?
      rescue
        false
      end

      def streaming_eligible?(account)
        return false unless hyperate_streaming_enabled?
        return false if account.blank? || !account.persisted?
        return false unless account.hyperate? && account.active? && account.connected?

        ::LiveMetrics.enabled_provider_names.include?(account.provider)
      rescue
        false
      end

      def pulsoid_streaming_enabled?
        async_enabled? &&
          SiteSetting.live_metrics_pulsoid_enabled &&
          SiteSetting.live_metrics_pulsoid_streaming_enabled &&
          ::LiveMetrics::PulsoidClient.configured? &&
          ::LiveMetrics::PulsoidStreamingClient.configured?
      rescue
        false
      end

      def pulsoid_streaming_eligible?(account)
        return false unless pulsoid_streaming_enabled?
        return false if account.blank? || !account.persisted?
        return false unless account.pulsoid? && account.active? && account.connected?

        ::LiveMetrics.enabled_provider_names.include?(account.provider)
      rescue
        false
      end

      def any_streaming_eligible?(account)
        streaming_eligible?(account) || pulsoid_streaming_eligible?(account)
      rescue
        false
      end

      # Eligibility for the legacy/background refresh chain. A provider account
      # is owned either by its dedicated streaming collector or by Sidekiq, never
      # by both at the same time.
      def eligible?(account)
        return false unless async_enabled?
        return false if account.blank? || !account.persisted?
        return false unless account.active? && account.connected?
        return false unless ::LiveMetrics.enabled_provider_names.include?(account.provider)
        return false if any_streaming_eligible?(account)

        true
      rescue
        false
      end

      def start(account, replace: false)
        if any_streaming_eligible?(account)
          stop(
            account,
            clear_state: false,
            clear_fetch_lock: false,
            invalidate_stream: false,
          )
          return nil
        end

        return stop(account) unless eligible?(account)

        # When a streaming feature flag is turned off, revoke the old guarded
        # writer before creating the HTTP generation. The socket may need a brief
        # moment to close, but it can no longer write current state.
        invalidate_stream_session(account, account.id)

        generation = SecureRandom.hex(16)
        created =
          if replace
            redis.set(loop_key(account.id), generation, ex: LOOP_TTL_SECONDS)
          else
            redis.set(loop_key(account.id), generation, nx: true, ex: LOOP_TTL_SECONDS)
          end

        return current_generation(account.id) if created.blank?

        unless enqueue_refresh(account.id, generation, delay_seconds: 0, attempt: 0)
          release_generation(account.id, generation)
          return nil
        end

        generation
      rescue => e
        log_failure("start", account&.id, e)
        nil
      end

      def restart(account)
        return nil if account.blank?

        if any_streaming_eligible?(account)
          # Invalidating the provider-specific session token makes the collector
          # close and replace the socket without allowing the old connection to
          # write another reading after a credential or provider change.
          stop(account, clear_state: true, clear_fetch_lock: false)
          return nil
        end

        # Invalidate the old generation and remove its state immediately, but do
        # not drop an in-flight fetch lock. The old job cannot be cancelled, and
        # retaining its lock prevents a reconnect from briefly running two
        # provider requests for the same account at once. The new generation
        # retries until the old fetch releases the lock.
        stop(account, clear_fetch_lock: false)
        start(account, replace: true)
      end

      def stop(
        account_or_id,
        clear_state: true,
        clear_fetch_lock: true,
        invalidate_stream: true
      )
        account_id = account_id_for(account_or_id)
        return false if account_id.blank?

        keys = [loop_key(account_id)]
        keys << fetch_lock_key(account_id) if clear_fetch_lock
        redis.del(*keys)
        invalidate_stream_session(account_or_id, account_id) if invalidate_stream
        ::LiveMetrics::CurrentStateStore.delete(account_id) if clear_state
        true
      rescue => e
        log_failure("stop", account_id, e)
        false
      end

      def sync_user(user_or_id)
        user_id = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
        return if user_id.to_i <= 0
        return unless provider_accounts_table_ready?

        ::LiveMetrics::ProviderAccount.where(user_id: user_id.to_i).find_each do |account|
          sync_account(account)
        end
      rescue => e
        ::LiveMetrics::SafeLog.warn(
          "refresh_coordinator_user_sync_failed",
          error: e,
          user_id: user_id,
        )
      end

      def sync_all
        return unless provider_accounts_table_ready?

        ::LiveMetrics::ProviderAccount.find_each do |account|
          sync_account(account)
        end
      rescue => e
        ::LiveMetrics::SafeLog.warn("refresh_coordinator_recovery_failed", error: e)
      end

      def generation_current?(account_or_id, generation)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || generation.blank?

        ActiveSupport::SecurityUtils.secure_compare(
          current_generation(account_id).to_s,
          generation.to_s,
        )
      rescue
        false
      end

      def release_generation(account_or_id, generation)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || generation.blank?

        redis.eval(
          RELEASE_LOCK_SCRIPT,
          keys: [namespaced_key(loop_key(account_id))],
          argv: [generation.to_s],
        ).to_i == 1
      rescue => e
        log_failure("release generation", account_id, e)
        false
      end

      def touch_generation(account_or_id, generation)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || generation.blank?

        redis.eval(
          TOUCH_GENERATION_SCRIPT,
          keys: [namespaced_key(loop_key(account_id))],
          argv: [generation.to_s, LOOP_TTL_SECONDS.to_s],
        ).to_i == 1
      rescue => e
        log_failure("touch generation", account_id, e)
        false
      end

      def write_state_if_current(account, live_payload, generation)
        return nil if account.blank? || generation.blank?

        ::LiveMetrics::CurrentStateStore.write_if(
          account,
          live_payload,
          guard_key: loop_key(account.id),
          guard_value: generation,
        )
      rescue => e
        log_failure("guarded state write", account&.id, e)
        nil
      end

      def acquire_fetch_lock(account_or_id)
        account_id = account_id_for(account_or_id)
        return nil if account_id.blank?

        token = SecureRandom.hex(16)
        acquired = redis.set(
          fetch_lock_key(account_id),
          token,
          nx: true,
          ex: FETCH_LOCK_TTL_SECONDS,
        )
        acquired.present? ? token : nil
      rescue => e
        log_failure("acquire fetch lock", account_id, e)
        nil
      end

      def release_fetch_lock(account_or_id, token)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || token.blank?

        redis.eval(
          RELEASE_LOCK_SCRIPT,
          keys: [namespaced_key(fetch_lock_key(account_id))],
          argv: [token.to_s],
        ).to_i == 1
      rescue => e
        log_failure("release fetch lock", account_id, e)
        false
      end

      def enqueue_refresh(account_or_id, generation, delay_seconds:, attempt:)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || generation.blank?
        return false unless generation_current?(account_id, generation)

        return false unless touch_generation(account_id, generation)

        ::Jobs.enqueue(
          ::Jobs::LiveMetrics::RefreshProviderAccount,
          account_id: account_id,
          generation: generation.to_s,
          attempt: [attempt.to_i, 0].max,
          delay_for: [delay_seconds.to_f, 0].max,
        )
        true
      rescue => e
        log_failure("enqueue", account_id, e)
        release_generation(account_id, generation) if account_id.present? && generation.present?
        false
      end

      def current_generation(account_or_id)
        account_id = account_id_for(account_or_id)
        return nil if account_id.blank?

        redis.get(loop_key(account_id))
      rescue
        nil
      end

      def loop_key(account_or_id)
        "#{LOOP_KEY_PREFIX}:#{account_id_for(account_or_id)}"
      end

      def fetch_lock_key(account_or_id)
        "#{FETCH_LOCK_KEY_PREFIX}:#{account_id_for(account_or_id)}"
      end

      private

      def sync_account(account)
        if any_streaming_eligible?(account)
          # Only remove the obsolete Sidekiq loop. The provider-specific streaming
          # collector owns the current Redis reading and must not be invalidated
          # by recovery or an unrelated visibility/settings update.
          stop(
            account,
            clear_state: false,
            clear_fetch_lock: false,
            invalidate_stream: false,
          )
        elsif eligible?(account)
          start(account)
        else
          stop(account)
        end
      end

      def invalidate_stream_session(account_or_id, account_id)
        provider = account_or_id.respond_to?(:provider) ? account_or_id.provider.to_s : nil

        if provider == ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
          ::LiveMetrics::HypeRateStreamingRegistry.invalidate_session(account_id) if defined?(::LiveMetrics::HypeRateStreamingRegistry)
        elsif provider == ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
          ::LiveMetrics::PulsoidStreamingRegistry.invalidate_session(account_id) if defined?(::LiveMetrics::PulsoidStreamingRegistry)
        else
          ::LiveMetrics::HypeRateStreamingRegistry.invalidate_session(account_id) if defined?(::LiveMetrics::HypeRateStreamingRegistry)
          ::LiveMetrics::PulsoidStreamingRegistry.invalidate_session(account_id) if defined?(::LiveMetrics::PulsoidStreamingRegistry)
        end
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

      def provider_accounts_table_ready?
        ::LiveMetrics::ProviderAccount.table_exists? &&
          %w[active show_on_user_card].all? do |column|
            ::LiveMetrics::ProviderAccount.column_names.include?(column)
          end
      rescue
        false
      end

      def log_failure(operation, account_id, error)
        ::LiveMetrics::SafeLog.warn(
          "refresh_coordinator_failed",
          error: error,
          operation: operation,
          account_id: account_id,
        )
      end
    end
  end
end
