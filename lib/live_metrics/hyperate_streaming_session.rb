# frozen_string_literal: true

require "securerandom"

module ::LiveMetrics
  class HypeRateStreamingSession
    StateAccount = Struct.new(:id, :provider, keyword_init: true)

    MAX_RECONNECT_DELAY_SECONDS = 30
    UNAUTHORIZED_RETRY_SECONDS = 60

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
      @stall_count = 0
      @frame_count = 0
      @reading_count = 0
      @last_successful_join_at_ms = nil
      @last_reconnect_reason = "none"
      @last_reconnect_at_ms = nil
      @known_last_error = :unknown
    end

    def start
      return false if account_id <= 0
      return false unless registry.activate_session(account_id, token)

      @thread = Thread.new { run }
      @thread.name = "live-metrics-hyperate-#{account_id}" if @thread.respond_to?(:name=)
      true
    rescue => e
      registry.release_session(account_id, token)
      record_stream_event(
        event: "stream_join",
        result: "start_failed",
        severity: "error",
      )
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

    def stalled?
      @mutex.synchronize { @stalled }
    end

    def unauthorized?
      status == :unauthorized
    end

    def last_event_age_seconds
      event_at = @mutex.synchronize { @last_event_monotonic }
      return nil if event_at.nil?

      [(monotonic_now - event_at).floor, 0].max
    end

    def last_frame_age_seconds
      frame_at = @mutex.synchronize { @last_frame_monotonic }
      return nil if frame_at.nil?

      [(monotonic_now - frame_at).floor, 0].max
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

    def stall_count
      @mutex.synchronize { @stall_count }
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
        reconnect_attempt = 0
        suppress_next_join_event = false

        until stop_requested?
          break unless session_current?

          snapshot = load_account_snapshot
          break if snapshot.blank?

          received_reading = false
          set_status(:connecting)

          begin
            ::LiveMetrics::HypeRateClient.stream(
              snapshot[:device_id],
              stop_if: -> { stop_requested? || !session_current? },
              on_socket: ->(socket) { set_socket(socket) },
              on_connected: lambda do
                record_connected(log_event: !suppress_next_join_event)
                suppress_next_join_event = false
                registry.touch_session(account_id, token)
              end,
              on_heartbeat: -> { registry.touch_session(account_id, token) },
              on_frame: -> { record_frame_received },
              on_reading: lambda do |payload|
                next unless session_current?

                received_reading = true
                reconnect_attempt = 0
                record_reading_received
                registry.touch_session(account_id, token)
                write_reading(payload)
                sync_last_error(snapshot, nil)
                set_status(:connected)
              end,
            )

            break if stop_requested? || !session_current?

            set_status(:reconnecting)
            record_reconnect(reason: :stream_ended)
            reconnect_attempt += 1 unless received_reading
            sleep_interruptibly(reconnect_delay(reconnect_attempt))
          rescue ::LiveMetrics::HypeRateClient::Unauthorized => e
            set_status(:unauthorized)
            record_retry_reason(:authorization_failed)
            write_error_state("unauthorized")
            sync_last_error(snapshot, "unauthorized")
            ::LiveMetrics::SafeLog.warn(
              "hyperate_stream_authorization_failed",
              error: e,
              account_id: account_id,
            )
            sleep_interruptibly(UNAUTHORIZED_RETRY_SECONDS)
          rescue ::LiveMetrics::HypeRateClient::StreamStalled => e
            set_status(:reconnecting)
            record_reconnect(reason: :transport_stalled, stalled: true)
            write_error_state("no_data")
            reconnect_attempt += 1
            ::LiveMetrics::SafeLog.warn(
              "hyperate_stream_watchdog_reconnect",
              error: e,
              account_id: account_id,
            )
            sleep_interruptibly(reconnect_delay(reconnect_attempt))
          rescue ::LiveMetrics::HypeRateClient::ReadingRecoveryDue
            # This is an expected, low-frequency subscription refresh. Keep it in
            # health counters without filling the bounded admin event log overnight.
            set_status(:reconnecting)
            record_reconnect(reason: :no_data, log_event: false)
            write_error_state("no_data")
            reconnect_attempt = 0
            suppress_next_join_event = true
            sleep_interruptibly(1)
          rescue ::LiveMetrics::HypeRateClient::NoHeartRateData => e
            set_status(:reconnecting)
            record_reconnect(reason: :no_data)
            write_error_state("no_data")
            reconnect_attempt += 1
            ::LiveMetrics::SafeLog.warn(
              "hyperate_stream_connection_ended",
              error: e,
              account_id: account_id,
            )
            sleep_interruptibly(reconnect_delay(reconnect_attempt))
          rescue IOError, EOFError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error => e
            break if stop_requested? || !session_current?

            set_status(:reconnecting)
            record_reconnect(reason: :transport_error)
            write_error_state("unavailable")
            reconnect_attempt += 1
            ::LiveMetrics::SafeLog.warn(
              "hyperate_stream_transport_failed",
              error: e,
              account_id: account_id,
            )
            sleep_interruptibly(reconnect_delay(reconnect_attempt))
          rescue => e
            break if stop_requested? || !session_current?

            set_status(:reconnecting)
            record_reconnect(reason: :unexpected_error)
            write_error_state("unavailable")
            reconnect_attempt += 1
            log_failure("run", e)
            sleep_interruptibly(reconnect_delay(reconnect_attempt))
          ensure
            set_socket(nil)
          end
        end
      end
    ensure
      set_status(:stopped)
      registry.release_session(account_id, token)
      clear_active_connections
    end

    def load_account_snapshot
      account = ::LiveMetrics::ProviderAccount.find_by(id: account_id)
      return nil unless ::LiveMetrics::RefreshCoordinator.streaming_eligible?(account)

      @known_last_error = account.last_error
      {
        device_id: ::LiveMetrics::HypeRateClient.normalize_device_id(account.provider_uid),
        provider: account.provider,
      }
    ensure
      clear_active_connections
    end

    def write_reading(payload)
      account = StateAccount.new(
        id: account_id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      )
      registry.write_state_if_current(account, payload, token)
    end

    def write_error_state(status)
      existing = ::LiveMetrics::CurrentStateStore.read(account_id)
      if status.to_s != "unauthorized" &&
           ::LiveMetrics::CurrentStateStore.state_with_reading?(existing)
        return
      end

      account = StateAccount.new(
        id: account_id,
        provider: ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      )
      registry.write_state_if_current(
        account,
        {
          status: status,
          heart_rate: nil,
          measured_at: nil,
          measured_at_ms: nil,
        },
        token,
      )
    end

    def sync_last_error(snapshot, desired_error)
      return unless session_current?
      return if @known_last_error == desired_error

      updated =
        ::LiveMetrics::ProviderAccount
          .where(
            id: account_id,
            provider: ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
            provider_uid: snapshot[:device_id],
            active: true,
          )
          .update_all(last_error: desired_error)
      @known_last_error = desired_error if updated == 1
    rescue => e
      ::LiveMetrics::SafeLog.warn(
        "hyperate_stream_error_state_sync_failed",
        error: e,
        account_id: account_id,
      )
    ensure
      clear_active_connections
    end

    def record_connected(log_event: true)
      joined_at_ms = current_time_ms
      recovered = false
      @mutex.synchronize do
        recovered = @last_successful_join_at_ms.present?
        @status = :connected
        @stalled = false
        @last_successful_join_at_ms = joined_at_ms
      end

      if log_event
        record_stream_event(
          event: "stream_join",
          result: recovered ? "recovered" : "success",
        )
      end
    end

    def record_frame_received
      now = monotonic_now
      @mutex.synchronize do
        @last_frame_monotonic = now
        @frame_count += 1
      end
    end

    def record_reading_received
      now = monotonic_now
      @mutex.synchronize do
        @last_event_monotonic = now
        @reading_count += 1
        @stalled = false
      end
    end

    def record_reconnect(reason: :unknown, stalled: false, log_event: true)
      reconnect_at_ms = current_time_ms
      normalized_reason = registry.sanitize_reconnect_reason(reason)

      @mutex.synchronize do
        @reconnect_count += 1
        @last_reconnect_reason = normalized_reason
        @last_reconnect_at_ms = reconnect_at_ms
        if stalled
          @stall_count += 1
          @stalled = true
        end
      end

      if log_event
        record_stream_event(
          event: "stream_reconnect",
          result: normalized_reason,
          severity: reconnect_severity(normalized_reason),
        )
      end
    end

    def record_retry_reason(reason)
      reconnect_at_ms = current_time_ms
      normalized_reason = registry.sanitize_reconnect_reason(reason)

      @mutex.synchronize do
        @last_reconnect_reason = normalized_reason
        @last_reconnect_at_ms = reconnect_at_ms
      end

      record_stream_event(
        event: "stream_reconnect",
        result: normalized_reason,
        severity: reconnect_severity(normalized_reason),
      )
    end

    def reconnect_severity(reason)
      case reason.to_s
      when "authorization_failed", "transport_stalled", "unexpected_error"
        "error"
      when "stream_ended", "no_data", "transport_error"
        "warning"
      else
        "info"
      end
    end

    def record_stream_event(event:, result:, severity: "info")
      ::LiveMetrics::AdminEventLog.record(
        provider: "hyperate",
        event: event,
        result: result,
        severity: severity,
        client_context: "server",
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def current_time_ms
      (Time.now.to_f * 1000).to_i
    end

    def reconnect_delay(attempt)
      exponent = [[attempt.to_i - 1, 0].max, 5].min
      base = [2**exponent, MAX_RECONNECT_DELAY_SECONDS].min
      jitter = SecureRandom.random_number(1000) / 1000.0
      [base + jitter, MAX_RECONNECT_DELAY_SECONDS].min
    end

    def sleep_interruptibly(seconds)
      remaining = [seconds.to_f, 0].max
      while remaining.positive? && !stop_requested? && session_current?
        slice = [remaining, 0.25].min
        sleep(slice)
        remaining -= slice
      end
    end

    def session_current?
      registry.session_current?(account_id, token)
    end

    def stop_requested?
      @mutex.synchronize { @stop_requested }
    end

    def set_socket(socket)
      @mutex.synchronize { @socket = socket }
    end

    def set_status(value)
      @mutex.synchronize { @status = value }
    end

    def registry
      ::LiveMetrics::HypeRateStreamingRegistry
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

    def log_failure(operation, error)
      ::LiveMetrics::SafeLog.warn(
        "hyperate_stream_session_failed",
        error: error,
        account_id: account_id,
        operation: operation,
      )
    end
  end
end
