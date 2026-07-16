# frozen_string_literal: true

require "securerandom"

module ::LiveMetrics
  class PulsoidStreamingSession
    StateAccount = Struct.new(:id, :provider, keyword_init: true)

    MAX_RECONNECT_DELAY_SECONDS = 30
    STABLE_CONNECTION_SECONDS = 10
    UNAUTHORIZED_RETRY_SECONDS = 60
    LONG_RETRY_SECONDS = 5.minutes.to_i
    CONFIGURATION_RETRY_SECONDS = 5.minutes.to_i

    attr_reader :account_id, :database, :fingerprint, :token

    def initialize(database:, account_id:, fingerprint:)
      @database = database.to_s
      @account_id = account_id.to_i
      @fingerprint = fingerprint.to_s
      @token = SecureRandom.hex(16)
      @stop_requested = false
      @thread = nil
      @socket = nil
      @mutex = Mutex.new
      @status = :starting
      @last_event_monotonic = nil
      @last_frame_monotonic = nil
      @stalled = false
      @reconnect_count = 0
      @frame_count = 0
      @reading_count = 0
      @authorization_failure_count = 0
      @last_successful_join_at_ms = nil
      @last_reconnect_reason = "none"
      @last_reconnect_at_ms = nil
      @known_last_error = :unknown
      @last_written_measured_at_ms = nil
    end

    def start
      return false if account_id <= 0
      return false unless registry.activate_session(account_id, token)

      @thread = Thread.new { run }
      @thread.name = "live-metrics-pulsoid-#{account_id}" if @thread.respond_to?(:name=)
      true
    rescue => e
      registry.release_session(account_id, token)
      record_stream_event(event: "stream_join", result: "start_failed", severity: "error")
      log_failure("start", e)
      false
    end

    def request_stop
      socket = nil
      @mutex.synchronize do
        @stop_requested = true
        socket = @socket
      end

      begin
        socket&.close
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end
      true
    end

    def join(timeout = 3)
      return true if @thread.blank?

      @thread.join(timeout)
      !@thread.alive?
    rescue
      false
    end

    def stop
      request_stop
      join
    ensure
      registry.release_session(account_id, token)
    end

    def alive?
      @thread&.alive? || false
    end

    def status
      @mutex.synchronize { @status }
    end

    def connected?
      status == :connected
    end

    def reconnecting?
      %i[starting connecting reconnecting].include?(status)
    end

    def unauthorized?
      status == :unauthorized
    end

    def subscription_required?
      status == :subscription_required
    end

    def scope_required?
      status == :scope_required
    end

    def stalled?
      @mutex.synchronize { @stalled }
    end

    def last_event_age_seconds
      age_for(@mutex.synchronize { @last_event_monotonic })
    end

    def last_frame_age_seconds
      age_for(@mutex.synchronize { @last_frame_monotonic })
    end

    def frame_count
      @mutex.synchronize { @frame_count }
    end

    def reading_count
      @mutex.synchronize { @reading_count }
    end

    def reconnect_count
      @mutex.synchronize { @reconnect_count }
    end

    def authorization_failure_count
      @mutex.synchronize { @authorization_failure_count }
    end

    def last_successful_join_at_ms
      @mutex.synchronize { @last_successful_join_at_ms }
    end

    def last_reconnect_reason
      @mutex.synchronize { @last_reconnect_reason }
    end

    def last_reconnect_at_ms
      @mutex.synchronize { @last_reconnect_at_ms }
    end

    private

    def run
      with_database do
        seed_last_written_timestamp
        reconnect_attempt = 0
        authorization_refresh_attempted = false

        until stop_requested?
          break unless session_current?
          break unless account_eligible?

          snapshot = nil
          token_refresh_due = false
          connected_at_monotonic = nil

          begin
            set_status(:connecting)
            snapshot = token_manager.snapshot(account_id)
            ::LiveMetrics::PulsoidStreamingClient.stream(
              snapshot.access_token,
              stop_if: lambda do
                token_refresh_due = socket_refresh_due?(snapshot)
                stop_requested? || !session_current? || token_refresh_due
              end,
              on_socket: ->(socket) { set_socket(socket) },
              on_connected: lambda do
                connected_at_monotonic = monotonic_now
                record_connected
                authorization_refresh_attempted = false
                registry.touch_session(account_id, token)
                write_error_state("no_data") if ::LiveMetrics::CurrentStateStore.read(account_id).blank?
              end,
              on_frame: lambda do
                reconnect_attempt = 0 if stable_connection?(connected_at_monotonic)
                record_frame_received
                registry.touch_session(account_id, token)
              end,
              on_ping: -> { registry.touch_session(account_id, token) },
              on_reading: lambda do |payload|
                next unless session_current?

                next unless write_reading(payload)

                reconnect_attempt = 0
                record_reading_received
                registry.touch_session(account_id, token)
                sync_last_error(snapshot, nil)
                set_status(:connected)
              end,
            )

            break if stop_requested? || !session_current? || !account_eligible?

            if token_refresh_due
              set_status(:reconnecting)
              record_reconnect(reason: :token_refresh_due)
              snapshot = token_manager.snapshot(account_id, force_refresh: true)
              next
            end

            reconnect_attempt = 0 if stable_connection?(connected_at_monotonic)
            set_status(:reconnecting)
            record_reconnect(reason: :stream_ended)
            reconnect_attempt += 1
            sleep_interruptibly(reconnect_delay(reconnect_attempt))
          rescue ::LiveMetrics::PulsoidStreamingClient::ProviderError => e
            break if stop_requested? || !session_current?

            reconnect_attempt = 0 if stable_connection?(connected_at_monotonic)
            if authorization_classification?(e.classification) && !authorization_refresh_attempted
              authorization_refresh_attempted = true
              begin
                snapshot = token_manager.snapshot(account_id, force_refresh: true)
                set_status(:reconnecting)
                record_reconnect(reason: :authorization_failed)
                next
              rescue => refresh_error
                handle_error(refresh_error, snapshot, reconnect_attempt)
                reconnect_attempt += 1
                sleep_interruptibly(retry_delay_for(refresh_error, reconnect_attempt))
                # Permit one new forced-refresh attempt in the next delayed
                # reconnect cycle. This never creates a tight refresh loop: the
                # failed attempt has already passed through bounded back-off.
                authorization_refresh_attempted = false
                next
              end
            end

            classification = classification_for(e)
            handle_error(e, snapshot, reconnect_attempt)
            reconnect_attempt += 1 unless long_wait_classification?(classification)
            sleep_interruptibly(retry_delay_for(e, reconnect_attempt))
            # A later reconnect cycle may make one fresh, lock-protected token
            # refresh attempt. Immediate duplicate refreshes remain prevented.
            authorization_refresh_attempted = false if authorization_classification?(classification)
          rescue ::LiveMetrics::PulsoidTokenManager::Error,
                 ::LiveMetrics::PulsoidClient::Error,
                 ::LiveMetrics::PulsoidStreamingClient::Error => e
            break if stop_requested? || !session_current?

            reconnect_attempt = 0 if stable_connection?(connected_at_monotonic)
            handle_error(e, snapshot, reconnect_attempt)
            reconnect_attempt += 1 unless long_wait_classification?(classification_for(e))
            sleep_interruptibly(retry_delay_for(e, reconnect_attempt))
          rescue IOError, EOFError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error => e
            break if stop_requested? || !session_current?

            reconnect_attempt = 0 if stable_connection?(connected_at_monotonic)
            set_status(:reconnecting)
            record_reconnect(reason: :transport_error)
            write_error_state("unavailable")
            reconnect_attempt += 1
            ::LiveMetrics::SafeLog.warn(
              "pulsoid_stream_transport_failed",
              error: e,
              account_id: account_id,
            )
            sleep_interruptibly(reconnect_delay(reconnect_attempt))
          rescue => e
            break if stop_requested? || !session_current?

            reconnect_attempt = 0 if stable_connection?(connected_at_monotonic)
            set_status(:reconnecting)
            record_reconnect(reason: :unexpected_error)
            write_error_state("unavailable")
            reconnect_attempt += 1
            log_failure("run", e)
            sleep_interruptibly(reconnect_delay(reconnect_attempt))
          ensure
            set_socket(nil)
            clear_active_connections
          end
        end
      end
    ensure
      set_status(:stopped)
      registry.release_session(account_id, token)
      clear_active_connections
    end

    def handle_error(error, snapshot, reconnect_attempt)
      classification = classification_for(error)

      case classification
      when :authorization_failed, :token_expired
        set_status(:unauthorized)
        increment_authorization_failure
        record_retry_reason(:authorization_failed)
        write_error_state("unauthorized")
        sync_last_error(snapshot, "reconnect_required")
      when :subscription_required
        set_status(:subscription_required)
        record_retry_reason(:subscription_required)
        write_error_state("unavailable")
        sync_last_error(snapshot, "subscription_required")
      when :scope_required
        set_status(:scope_required)
        record_retry_reason(:scope_required)
        write_error_state("unauthorized")
        sync_last_error(snapshot, "scope_required")
      when :configuration_error
        set_status(:reconnecting)
        record_retry_reason(:configuration_error)
        write_error_state("unavailable")
        sync_last_error(snapshot, "reconnect_required")
      when :protocol_error
        set_status(:reconnecting)
        record_reconnect(reason: :protocol_error)
        write_error_state("unavailable")
      when :transport_stalled
        set_status(:reconnecting)
        record_reconnect(reason: :transport_stalled, stalled: true)
        write_error_state("unavailable")
      when :rate_limited
        set_status(:reconnecting)
        record_reconnect(reason: :rate_limited)
        write_error_state("unavailable")
      when :provider_unavailable
        set_status(:reconnecting)
        record_reconnect(reason: :provider_unavailable)
        write_error_state("unavailable")
      when :stream_ended
        set_status(:reconnecting)
        record_reconnect(reason: :stream_ended)
      else
        set_status(:reconnecting)
        record_reconnect(reason: :unexpected_error)
        write_error_state("unavailable")
      end

      ::LiveMetrics::SafeLog.warn(
        "pulsoid_stream_provider_failed",
        error: error,
        account_id: account_id,
        classification: registry.sanitize_reconnect_reason(classification),
        attempt: reconnect_attempt.to_i,
      )
    end

    def retry_delay_for(error, reconnect_attempt)
      case classification_for(error)
      when :authorization_failed, :token_expired
        UNAUTHORIZED_RETRY_SECONDS
      when :subscription_required, :scope_required
        LONG_RETRY_SECONDS
      when :configuration_error
        CONFIGURATION_RETRY_SECONDS
      else
        reconnect_delay([reconnect_attempt, 1].max)
      end
    end

    def classification_for(error)
      return error.classification.to_sym if error.respond_to?(:classification) && error.classification.present?

      case error
      when ::LiveMetrics::PulsoidClient::Unauthorized,
           ::LiveMetrics::PulsoidTokenManager::MissingCredentials,
           ::LiveMetrics::PulsoidTokenManager::AccountUnavailable
        :authorization_failed
      when ::LiveMetrics::PulsoidTokenManager::RefreshBusy
        :provider_unavailable
      else
        :unexpected_error
      end
    end

    def authorization_classification?(classification)
      %i[authorization_failed token_expired].include?(classification.to_sym)
    end

    def long_wait_classification?(classification)
      %i[authorization_failed token_expired subscription_required scope_required configuration_error].include?(
        classification.to_sym,
      )
    end

    def account_eligible?
      account = ::LiveMetrics::ProviderAccount.find_by(id: account_id)
      ::LiveMetrics::RefreshCoordinator.pulsoid_streaming_eligible?(account)
    ensure
      clear_active_connections
    end

    def write_reading(payload)
      measured_at_ms = payload&.with_indifferent_access&.dig(:measured_at_ms).to_i
      return false if measured_at_ms <= 0

      accepted = @mutex.synchronize do
        @last_written_measured_at_ms.blank? || measured_at_ms > @last_written_measured_at_ms
      end
      return false unless accepted

      account = StateAccount.new(
        id: account_id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
      )
      written = registry.write_state_if_current(account, payload, token)
      if written.present?
        @mutex.synchronize do
          @last_written_measured_at_ms = [@last_written_measured_at_ms.to_i, measured_at_ms].max
        end
        return true
      end

      false
    end

    def seed_last_written_timestamp
      state = ::LiveMetrics::CurrentStateStore.read(account_id)
      measured_at_ms = state&.dig(:measured_at_ms).to_i
      @mutex.synchronize do
        @last_written_measured_at_ms = measured_at_ms if measured_at_ms.positive?
      end
    rescue
      nil
    end

    def write_error_state(status)
      existing = ::LiveMetrics::CurrentStateStore.read(account_id)
      if status.to_s != "unauthorized" && ::LiveMetrics::CurrentStateStore.state_with_reading?(existing)
        return
      end

      account = StateAccount.new(
        id: account_id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
      )
      registry.write_state_if_current(
        account,
        { status: status, heart_rate: nil, measured_at: nil, measured_at_ms: nil },
        token,
      )
    end

    def sync_last_error(snapshot, desired_error)
      return unless session_current?
      return if @known_last_error == desired_error

      account = ::LiveMetrics::ProviderAccount.find_by(id: account_id)
      return unless ::LiveMetrics::RefreshCoordinator.pulsoid_streaming_eligible?(account)
      if snapshot.present?
        return unless token_manager.credential_fingerprint(account) == snapshot.credential_fingerprint
      end

      updated =
        ::LiveMetrics::ProviderAccount
          .where(
            id: account_id,
            provider: ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
            active: true,
            updated_at: account.updated_at,
            access_token_cipher: account.access_token_cipher,
            refresh_token_cipher: account.refresh_token_cipher,
          )
          .update_all(last_error: desired_error)
      @known_last_error = desired_error if updated == 1
    rescue => e
      ::LiveMetrics::SafeLog.warn(
        "pulsoid_stream_error_state_sync_failed",
        error: e,
        account_id: account_id,
      )
    ensure
      clear_active_connections
    end

    def record_connected
      joined_at_ms = current_time_ms
      recovered = false
      @mutex.synchronize do
        recovered = @last_successful_join_at_ms.present?
        @status = :connected
        @stalled = false
        @last_successful_join_at_ms = joined_at_ms
      end
      record_stream_event(event: "stream_join", result: recovered ? "recovered" : "success")
    end

    def record_frame_received
      now = monotonic_now
      @mutex.synchronize do
        @last_frame_monotonic = now
        @frame_count += 1
        @stalled = false
      end
    end

    def record_reading_received
      now = monotonic_now
      @mutex.synchronize do
        @last_event_monotonic = now
        @last_frame_monotonic = now
        @reading_count += 1
        @stalled = false
      end
    end

    def record_reconnect(reason:, stalled: false)
      sanitized_reason = registry.sanitize_reconnect_reason(reason)
      @mutex.synchronize do
        @reconnect_count += 1
        @stalled = true if stalled
        @last_reconnect_reason = sanitized_reason
        @last_reconnect_at_ms = current_time_ms
      end
      record_stream_event(
        event: "stream_reconnect",
        result: sanitized_reason,
        severity: reconnect_severity(sanitized_reason),
      )
    end

    def record_retry_reason(reason)
      sanitized_reason = registry.sanitize_reconnect_reason(reason)
      @mutex.synchronize do
        @last_reconnect_reason = sanitized_reason
        @last_reconnect_at_ms = current_time_ms
      end
      record_stream_event(
        event: "stream_reconnect",
        result: sanitized_reason,
        severity: reconnect_severity(sanitized_reason),
      )
    end

    def reconnect_severity(reason)
      case reason.to_s
      when "authorization_failed", "configuration_error", "protocol_error", "unexpected_error"
        "error"
      when "token_refresh_due"
        "info"
      else
        "warning"
      end
    end

    def increment_authorization_failure
      @mutex.synchronize { @authorization_failure_count += 1 }
    end

    def record_stream_event(event:, result:, severity: "info")
      ::LiveMetrics::AdminEventLog.record(
        provider: "pulsoid",
        event: event,
        result: result,
        severity: severity,
        client_context: "server",
      )
    rescue
      nil
    end

    def stable_connection?(connected_at_monotonic)
      connected_at_monotonic.present? &&
        (monotonic_now - connected_at_monotonic) >= STABLE_CONNECTION_SECONDS
    end

    def socket_refresh_due?(snapshot)
      deadline = snapshot.socket_refresh_deadline
      deadline.present? && Time.zone.now >= deadline
    end

    def reconnect_delay(attempt)
      exponent = [[attempt.to_i - 1, 0].max, 5].min
      base = [2**exponent, MAX_RECONNECT_DELAY_SECONDS].min.to_f
      jitter = SecureRandom.random_number(1000) / 1000.0
      [base + jitter, MAX_RECONNECT_DELAY_SECONDS].min
    end

    def sleep_interruptibly(seconds)
      remaining = seconds.to_f
      while remaining.positive? && !stop_requested? && session_current?
        slice = [remaining, 0.25].min
        sleep(slice)
        remaining -= slice
      end
    end

    def set_status(value)
      @mutex.synchronize { @status = value.to_sym }
    end

    def set_socket(socket)
      @mutex.synchronize { @socket = socket }
    end

    def stop_requested?
      @mutex.synchronize { @stop_requested }
    end

    def session_current?
      registry.session_current?(account_id, token)
    end

    def age_for(value)
      return nil if value.nil?

      [(monotonic_now - value).floor, 0].max
    end

    def registry
      ::LiveMetrics::PulsoidStreamingRegistry
    end

    def token_manager
      ::LiveMetrics::PulsoidTokenManager
    end

    def with_database(&block)
      if defined?(RailsMultisite::ConnectionManagement)
        RailsMultisite::ConnectionManagement.with_connection(database, &block)
      else
        yield
      end
    end

    def clear_active_connections
      ActiveRecord::Base.connection_handler.clear_active_connections!
    rescue
      nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def current_time_ms
      (Time.now.to_f * 1000).to_i
    end

    def log_failure(operation, error)
      ::LiveMetrics::SafeLog.warn(
        "pulsoid_stream_session_failed",
        error: error,
        operation: operation,
        account_id: account_id,
      )
    end
  end
end
