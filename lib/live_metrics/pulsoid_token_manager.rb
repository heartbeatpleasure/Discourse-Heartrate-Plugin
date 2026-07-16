# frozen_string_literal: true

require "digest"
require "securerandom"

module ::LiveMetrics
  class PulsoidTokenManager
    LOCK_KEY_PREFIX = "live_metrics:pulsoid:token_refresh_lock:v1"
    LOCK_TTL_SECONDS = 30
    LOCK_WAIT_SECONDS = 3
    WAIT_MIN_SECONDS = 0.08
    WAIT_JITTER_SECONDS = 0.12
    SOCKET_REFRESH_MARGIN_SECONDS = 90

    RELEASE_LOCK_SCRIPT = <<~LUA.freeze
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
      end
      return 0
    LUA

    class Error < StandardError; end
    class MissingCredentials < Error; end
    class RefreshBusy < Error; end
    class AccountUnavailable < Error; end

    class Snapshot
      attr_reader :account_id, :access_token, :expires_at, :credential_fingerprint

      def initialize(account_id:, access_token:, expires_at:, credential_fingerprint:)
        @account_id = account_id.to_i
        @access_token = access_token.to_s
        @expires_at = expires_at
        @credential_fingerprint = credential_fingerprint.to_s
        freeze
      end

      def socket_refresh_deadline
        return nil if expires_at.blank?

        expires_at - ::LiveMetrics::PulsoidTokenManager::SOCKET_REFRESH_MARGIN_SECONDS.seconds
      end

      def inspect
        "#<#{self.class.name} account_id=#{account_id} expires_at=#{expires_at&.iso8601}>"
      end
    end

    class << self
      def snapshot(account_or_id, force_refresh: false)
        account_id = account_id_for(account_or_id)
        raise AccountUnavailable, "Pulsoid account is unavailable." if account_id.blank?

        initial = load_account!(account_id)
        initial_fingerprint = credential_fingerprint(initial)
        return build_snapshot(initial) unless refresh_required?(initial, force_refresh: force_refresh)

        lock_token = acquire_lock(account_id)
        if lock_token.present?
          begin
            account = load_account!(account_id)
            another_refresh_completed = credential_fingerprint(account) != initial_fingerprint

            if refresh_required?(account, force_refresh: force_refresh && !another_refresh_completed)
              begin
                ::LiveMetrics::PulsoidClient.refresh!(account)
              rescue ::LiveMetrics::PulsoidClient::StaleCredentials
                account = load_account!(account_id)
              end
            end

            return build_snapshot(load_account!(account_id))
          ensure
            release_lock(account_id, lock_token)
          end
        end

        wait_for_refresh(account_id, initial_fingerprint, force_refresh: force_refresh)
      end

      def acquire_lock(account_or_id)
        account_id = account_id_for(account_or_id)
        return nil if account_id.blank?

        token = SecureRandom.hex(16)
        acquired = redis.set(lock_key(account_id), token, nx: true, ex: LOCK_TTL_SECONDS)
        acquired.present? ? token : nil
      rescue => e
        ::LiveMetrics::SafeLog.warn(
          "pulsoid_token_refresh_lock_failed",
          error: e,
          account_id: account_id,
          operation: "acquire",
        )
        nil
      end

      def release_lock(account_or_id, token)
        account_id = account_id_for(account_or_id)
        return false if account_id.blank? || token.blank?

        redis.eval(
          RELEASE_LOCK_SCRIPT,
          keys: [namespaced_key(lock_key(account_id))],
          argv: [token.to_s],
        ).to_i == 1
      rescue => e
        ::LiveMetrics::SafeLog.warn(
          "pulsoid_token_refresh_lock_failed",
          error: e,
          account_id: account_id,
          operation: "release",
        )
        false
      end

      def lock_key(account_or_id)
        account_id = account_id_for(account_or_id)
        "#{LOCK_KEY_PREFIX}:#{account_id}"
      end

      def credential_fingerprint(account)
        Digest::SHA256.hexdigest(
          [
            account.id.to_i,
            account.access_token_cipher.to_s,
            account.refresh_token_cipher.to_s,
            account.token_expires_at&.to_f,
          ].join("\0"),
        )
      end

      private

      def wait_for_refresh(account_id, initial_fingerprint, force_refresh:)
        deadline = monotonic_now + LOCK_WAIT_SECONDS

        loop do
          sleep(WAIT_MIN_SECONDS + SecureRandom.random_number * WAIT_JITTER_SECONDS)
          account = load_account!(account_id)
          changed = credential_fingerprint(account) != initial_fingerprint
          return build_snapshot(account) if changed || !refresh_required?(account, force_refresh: force_refresh)

          break if monotonic_now >= deadline
        end

        raise RefreshBusy, "Pulsoid token refresh is already in progress."
      end

      def load_account!(account_id)
        account = ::LiveMetrics::ProviderAccount.find_by(id: account_id)
        unless account&.pulsoid? && account.connected?
          raise AccountUnavailable, "Pulsoid account is no longer connected."
        end

        account
      end

      def refresh_required?(account, force_refresh:)
        force_refresh || account.token_refresh_recommended?
      end

      def build_snapshot(account)
        access_token = account.access_token
        if access_token.blank? || account.refresh_token_cipher.blank?
          raise MissingCredentials, "Pulsoid credentials are incomplete."
        end

        Snapshot.new(
          account_id: account.id,
          access_token: access_token,
          expires_at: account.token_expires_at,
          credential_fingerprint: credential_fingerprint(account),
        )
      end

      def account_id_for(account_or_id)
        value = account_or_id.respond_to?(:id) ? account_or_id.id : account_or_id
        id = value.to_i
        id.positive? ? id : nil
      end

      def redis
        Discourse.redis
      end

      def namespaced_key(logical_key)
        redis.namespace_key(logical_key.to_s)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
