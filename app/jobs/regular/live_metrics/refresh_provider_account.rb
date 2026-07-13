# frozen_string_literal: true

require "securerandom"

module Jobs
  module LiveMetrics
    class RefreshProviderAccount < ::Jobs::Base
      sidekiq_options queue: "low", retry: false, concurrency: 5

      MAX_BACKOFF_SECONDS = 60
      MIN_NO_DATA_DELAY_SECONDS = 5
      LOCK_RETRY_DELAY_SECONDS = 2

      def execute(args)
        account_id = args[:account_id].to_i
        generation = args[:generation].to_s
        attempt = [args[:attempt].to_i, 0].max
        return if account_id <= 0 || generation.blank?
        return unless coordinator.generation_current?(account_id, generation)

        account = ::LiveMetrics::ProviderAccount.find_by(id: account_id)
        unless coordinator.eligible?(account)
          coordinator.stop(account_id)
          return
        end

        return unless coordinator.touch_generation(account_id, generation)

        lock_token = coordinator.acquire_fetch_lock(account_id)
        unless lock_token
          # This can happen briefly when the same account is reconnected while
          # an old generation is still finishing its provider request. The old
          # generation is not allowed to reschedule, so keep this new generation
          # alive and retry after a short delay. Normal startup/recovery creates
          # only one job chain per generation.
          coordinator.enqueue_refresh(
            account_id,
            generation,
            delay_seconds: LOCK_RETRY_DELAY_SECONDS,
            attempt: attempt,
          )
          return
        end

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        next_delay = nil
        next_attempt = attempt

        begin
          provider_state = fetch_latest(account)
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

          if generation_still_valid?(account, generation)
            persist_provider_state(account, provider_state, generation)
            sync_account_error_state(account, provider_state, generation)
            next_delay, next_attempt = next_schedule(provider_state, duration, attempt)
          end
        rescue => e
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          Rails.logger.warn(
            "[live_metrics] provider refresh failed account_id=#{account_id} provider=#{account.provider} error=#{e.class}: #{e.message}",
          )

          if generation_still_valid?(account, generation)
            persist_provider_state(account, unavailable_state, generation)
            next_delay, next_attempt = next_schedule(unavailable_state, duration, attempt)
          end
        ensure
          coordinator.release_fetch_lock(account_id, lock_token)
        end

        return if next_delay.nil?
        return unless generation_still_valid?(account, generation)

        coordinator.enqueue_refresh(
          account_id,
          generation,
          delay_seconds: next_delay,
          attempt: next_attempt,
        )
      end

      private

      def coordinator
        ::LiveMetrics::RefreshCoordinator
      end

      def store
        ::LiveMetrics::CurrentStateStore
      end

      def fetch_latest(account)
        case account.provider
        when ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID
          ::LiveMetrics::PulsoidClient.fetch_latest(account, persist_last_error: false)
        when ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE
          ::LiveMetrics::HypeRateClient.fetch_latest(account, persist_last_error: false)
        else
          unavailable_state
        end
      end

      def persist_provider_state(account, provider_state, generation)
        state = (provider_state || {}).with_indifferent_access
        status = state[:status].to_s

        if valid_reading?(state) || status == "unauthorized"
          coordinator.write_state_if_current(account, state, generation)
          return
        end

        # Do not immediately replace a recent valid reading with a transient
        # timeout/unavailable result. The prior state ages naturally and expires
        # under the hard Redis TTL. When no reading exists yet, store the error
        # state so the owner sees a useful non-live status.
        existing = store.read(account)
        unless store.state_with_reading?(existing)
          coordinator.write_state_if_current(account, state, generation)
        end
      end

      def sync_account_error_state(account, provider_state, generation)
        state = (provider_state || {}).with_indifferent_access
        desired_error =
          case state[:status].to_s
          when "unauthorized"
            "unauthorized"
          when "live", "delayed", "stale", "no_data"
            nil
          else
            return
          end

        return if account.last_error == desired_error
        return unless coordinator.generation_current?(account.id, generation)

        # The updated_at predicate prevents an old in-flight refresh from
        # changing last_error after reconnect, credential/device replacement,
        # provider switching, or another account mutation.
        attributes = { last_error: desired_error }
        attributes[:updated_at] = Time.zone.now if desired_error.present?
        scope =
          ::LiveMetrics::ProviderAccount.where(
            id: account.id,
            provider: account.provider,
            active: true,
            updated_at: account.updated_at,
          )
        scope =
          if account.pulsoid?
            scope.where(
              access_token_cipher: account.access_token_cipher,
              refresh_token_cipher: account.refresh_token_cipher,
            )
          elsif account.hyperate?
            scope.where(provider_uid: account.provider_uid)
          else
            scope.none
          end
        updated = scope.update_all(attributes)

        if updated == 1
          account.last_error = desired_error
          account.updated_at = attributes[:updated_at] if attributes[:updated_at].present?
        end
      rescue => e
        Rails.logger.warn(
          "[live_metrics] provider error-state sync failed account_id=#{account&.id} provider=#{account&.provider} error=#{e.class}: #{e.message}",
        )
      end

      def valid_reading?(state)
        state[:heart_rate].to_i.positive? &&
          (state[:measured_at_ms].to_i.positive? || state[:measured_at].present?)
      end

      def next_schedule(provider_state, duration, attempt)
        status = provider_state&.with_indifferent_access&.dig(:status).to_s
        target_interval = [SiteSetting.live_metrics_provider_refresh_interval_seconds.to_i, 1].max

        case status
        when "live", "delayed", "stale"
          [[target_interval - duration, 0].max, 0]
        when "unauthorized"
          [MAX_BACKOFF_SECONDS, [attempt + 1, 10].min]
        when "no_data"
          next_attempt = [attempt + 1, 10].min
          [
            [target_interval, exponential_backoff(next_attempt, base: MIN_NO_DATA_DELAY_SECONDS)].max,
            next_attempt,
          ]
        else
          next_attempt = [attempt + 1, 10].min
          [exponential_backoff(next_attempt, base: 5, jitter: true), next_attempt]
        end
      end

      def exponential_backoff(attempt, base:, jitter: false)
        seconds = [base * (2**([attempt - 1, 0].max)), MAX_BACKOFF_SECONDS].min.to_f
        seconds += SecureRandom.random_number(1500) / 1000.0 if jitter && seconds < MAX_BACKOFF_SECONDS
        [seconds, MAX_BACKOFF_SECONDS].min
      end

      def generation_still_valid?(account, generation)
        account.reload
        coordinator.eligible?(account) && coordinator.generation_current?(account.id, generation)
      rescue ActiveRecord::RecordNotFound
        false
      end

      def unavailable_state
        {
          status: "unavailable",
          heart_rate: nil,
          measured_at: nil,
          measured_at_ms: nil,
        }
      end
    end
  end
end
