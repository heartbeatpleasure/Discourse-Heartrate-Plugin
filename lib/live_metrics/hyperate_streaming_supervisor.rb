# frozen_string_literal: true

require "digest"
require "securerandom"

module ::LiveMetrics
  # Runs in a dedicated Discourse demon process. Each active HypeRate account
  # gets one blocking-I/O thread and one persistent WebSocket; no Sidekiq thread
  # is occupied. The configurable hard cap bounds memory and provider sockets.
  class HypeRateStreamingSupervisor
    RECONCILE_INTERVAL_SECONDS = 1

    def initialize
      @stopping = false
      @sessions = {}
      @leader_tokens = {}
      @overflow_logged = {}
    end

    def run
      until stopping?
        databases.each do |database|
          break if stopping?

          with_database(database) { reconcile_database(database) }
        rescue => e
          Rails.logger.warn(
            "[live_metrics] HypeRate streaming reconcile failed database=#{database} error=#{e.class}: #{e.message}",
          )
          stop_database_sessions(database, clear_state: false)
        ensure
          clear_active_connections
        end

        sleep_interruptibly(RECONCILE_INTERVAL_SECONDS)
      end
    ensure
      stop_all_sessions(clear_state: false)
      release_all_leaders
    end

    def request_stop
      @stopping = true
      @sessions.values.each(&:request_stop)
    end

    private

    def reconcile_database(database)
      unless ::LiveMetrics::RefreshCoordinator.hyperate_streaming_enabled?
        stop_database_sessions(database, clear_state: false)
        release_leader(database)
        registry.clear_health
        return
      end

      return lose_leadership(database) unless ensure_leader(database)

      desired = desired_accounts
      session_keys_for(database).each do |key|
        account_id = key.last
        session = @sessions[key]
        expected = desired[account_id]

        if expected.blank?
          stop_session(key, clear_state: true)
        elsif !session.alive? || session.fingerprint != expected[:fingerprint]
          stop_session(key, clear_state: false)
          start_session(database, account_id, expected[:fingerprint])
        else
          registry.touch_session(account_id, session.token)
        end
      end

      desired.each do |account_id, metadata|
        key = session_key(database, account_id)
        next if @sessions[key]&.alive?

        start_session(database, account_id, metadata[:fingerprint])
      end

      publish_health(database)
    end

    def desired_accounts
      limit = max_streams
      rows =
        ::LiveMetrics::ProviderAccount
          .hyperate
          .active
          .where.not(provider_uid: [nil, ""])
          .order(:id)
          .limit(limit + 1)
          .pluck(:id, :provider_uid)

      overflow = rows.length > limit
      rows = rows.first(limit)
      log_overflow_once(overflow, limit)

      settings_fingerprint = Digest::SHA256.hexdigest(
        [
          SiteSetting.live_metrics_hyperate_api_key.to_s,
          SiteSetting.live_metrics_hyperate_ws_url.to_s,
          SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds.to_i,
        ].join("\0"),
      )

      rows.each_with_object({}) do |(account_id, provider_uid), result|
        device_id = ::LiveMetrics::HypeRateClient.normalize_device_id(provider_uid)
        next unless ::LiveMetrics::HypeRateClient.valid_device_id?(device_id)

        result[account_id.to_i] = {
          fingerprint: Digest::SHA256.hexdigest(
            [account_id.to_i, device_id, settings_fingerprint].join("\0"),
          ),
        }
      end
    end

    def start_session(database, account_id, fingerprint)
      session = ::LiveMetrics::HypeRateStreamingSession.new(
        database: database,
        account_id: account_id,
        fingerprint: fingerprint,
      )
      key = session_key(database, account_id)

      if session.start
        @sessions[key] = session
      else
        ::LiveMetrics::CurrentStateStore.delete(account_id)
      end
    rescue => e
      Rails.logger.warn(
        "[live_metrics] HypeRate streaming session start failed account_id=#{account_id} error=#{e.class}: #{e.message}",
      )
    end

    def stop_session(key, clear_state:)
      session = @sessions.delete(key)
      return if session.blank?

      session.request_stop
      session.join(3)
      registry.release_session(session.account_id, session.token)
      ::LiveMetrics::CurrentStateStore.delete(session.account_id) if clear_state
    rescue => e
      Rails.logger.warn(
        "[live_metrics] HypeRate streaming session stop failed account_id=#{session&.account_id} error=#{e.class}: #{e.message}",
      )
    end

    def stop_database_sessions(database, clear_state:)
      keys = session_keys_for(database)
      sessions = keys.filter_map { |key| @sessions[key] }
      sessions.each(&:request_stop)
      join_sessions(sessions, total_timeout: 5)

      keys.each do |key|
        session = @sessions.delete(key)
        next if session.blank?

        registry.release_session(session.account_id, session.token)
        ::LiveMetrics::CurrentStateStore.delete(session.account_id) if clear_state
      end
    end

    def stop_all_sessions(clear_state:)
      sessions = @sessions.values
      sessions.each(&:request_stop)
      join_sessions(sessions, total_timeout: 5)

      @sessions.each_value do |session|
        with_database(session.database) do
          registry.release_session(session.account_id, session.token)
          ::LiveMetrics::CurrentStateStore.delete(session.account_id) if clear_state
        end
      rescue
        nil
      end
      @sessions.clear
    end

    def join_sessions(sessions, total_timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + total_timeout.to_f
      sessions.each do |session|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0

        session.join(remaining)
      end
    end

    def publish_health(database)
      sessions = session_keys_for(database).filter_map { |key| @sessions[key] }
      event_ages = sessions.filter_map(&:last_event_age_seconds)
      frame_ages = sessions.filter_map(&:last_frame_age_seconds)
      registry.publish_health(
        sessions: sessions.count,
        connected: sessions.count(&:connected?),
        reconnecting: sessions.count(&:reconnecting?),
        stalled: sessions.count(&:stalled?),
        oldest_event_age_seconds: event_ages.max,
        oldest_frame_age_seconds: frame_ages.max,
        frames: sessions.sum(&:frame_count),
        readings: sessions.sum(&:reading_count),
        reconnects: sessions.sum(&:reconnect_count),
        stalls: sessions.sum(&:stall_count),
        limit: max_streams,
      )
    end

    def ensure_leader(database)
      token = (@leader_tokens[database] ||= SecureRandom.hex(16))
      registry.acquire_or_renew_leader(token)
    end

    def lose_leadership(database)
      stop_database_sessions(database, clear_state: false)
      @leader_tokens.delete(database)
    end

    def release_leader(database)
      token = @leader_tokens.delete(database)
      registry.release_leader(token) if token.present?
    end

    def release_all_leaders
      @leader_tokens.keys.each do |database|
        with_database(database) { release_leader(database) }
      rescue
        nil
      end
    end

    def max_streams
      value = SiteSetting.live_metrics_hyperate_max_streams.to_i
      value = 100 if value <= 0
      value.clamp(1, 500)
    end

    def log_overflow_once(overflow, limit)
      database = current_database
      if overflow
        return if @overflow_logged[database] == limit

        @overflow_logged[database] = limit
        Rails.logger.warn(
          "[live_metrics] HypeRate streaming connection limit reached limit=#{limit}; additional active accounts will wait.",
        )
      else
        @overflow_logged.delete(database)
      end
    end

    def session_keys_for(database)
      @sessions.keys.select { |key| key.first == database.to_s }
    end

    def session_key(database, account_id)
      [database.to_s, account_id.to_i]
    end

    def registry
      ::LiveMetrics::HypeRateStreamingRegistry
    end

    def databases
      if defined?(RailsMultisite::ConnectionManagement)
        RailsMultisite::ConnectionManagement.all_dbs
      else
        ["default"]
      end
    rescue
      ["default"]
    end

    def current_database
      if defined?(RailsMultisite::ConnectionManagement)
        RailsMultisite::ConnectionManagement.current_db.to_s
      else
        "default"
      end
    end

    def with_database(database, &block)
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

    def stopping?
      @stopping
    end

    def sleep_interruptibly(seconds)
      remaining = seconds.to_f
      while remaining.positive? && !stopping?
        slice = [remaining, 0.25].min
        sleep(slice)
        remaining -= slice
      end
    end
  end
end
