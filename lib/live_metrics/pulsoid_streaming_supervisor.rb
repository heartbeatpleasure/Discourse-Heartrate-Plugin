# frozen_string_literal: true

require "digest"
require "securerandom"

module ::LiveMetrics
  class PulsoidStreamingSupervisor
    RECONCILE_INTERVAL_SECONDS = 1

    def initialize
      @sessions = {}
      @leader_tokens = {}
      @stopping = false
      @collector_started_at_ms = current_time_ms
      @limit_reached = {}
      @limit_event_logged = {}
      @overflow_logged = {}
      @last_reconnect_events = {}
      @last_successful_joins = {}
      @counter_totals = Hash.new { |hash, key| hash[key] = empty_counter_totals }
      @desired_counts = {}
    end

    def run
      until stopping?
        databases.each do |database|
          break if stopping?

          with_database(database) { reconcile_database(database) }
          clear_active_connections
        rescue => e
          ::LiveMetrics::SafeLog.warn(
            "pulsoid_stream_supervisor_reconcile_failed",
            error: e,
            database: database,
          )
        ensure
          clear_active_connections
        end

        sleep_interruptibly(RECONCILE_INTERVAL_SECONDS)
      end
    ensure
      stop_all_sessions(clear_state: false)
      release_all_leaders
      clear_active_connections
    end

    def request_stop
      @stopping = true
      @sessions.values.each(&:request_stop)
      true
    end

    private

    def reconcile_database(database)
      unless operational?
        stop_database_sessions(database, clear_state: false)
        release_leader(database)
        registry.clear_health
        clear_database_health_metadata(database)
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

    def operational?
      ::LiveMetrics::RefreshCoordinator.pulsoid_streaming_enabled?
    rescue
      false
    end

    def desired_accounts
      limit = max_streams
      relation =
        ::LiveMetrics::ProviderAccount
          .pulsoid
          .active
          .where.not(access_token_cipher: [nil, ""])
          .where.not(refresh_token_cipher: [nil, ""])
          .order(:id)

      rows = relation.limit(limit + 1).pluck(
        :id,
        :access_token_cipher,
        :refresh_token_cipher,
        :token_expires_at,
      )
      overflow = rows.length > limit
      database = current_database
      @desired_counts[database] = rows.length
      @limit_reached[database] = overflow
      rows = rows.first(limit)
      log_overflow_once(overflow, limit)
      log_limit_reached_once(overflow, limit)

      settings_fingerprint = Digest::SHA256.hexdigest(
        [
          SiteSetting.live_metrics_pulsoid_ws_url.to_s,
          SiteSetting.live_metrics_pulsoid_stream_transport_timeout_seconds.to_i,
          SiteSetting.live_metrics_pulsoid_client_id.to_s,
          SiteSetting.live_metrics_pulsoid_token_url.to_s,
        ].join("\0"),
      )

      rows.each_with_object({}) do |row, result|
        account_id, access_cipher, refresh_cipher, expires_at = row
        result[account_id.to_i] = {
          fingerprint: Digest::SHA256.hexdigest(
            [
              account_id.to_i,
              access_cipher.to_s,
              refresh_cipher.to_s,
              expires_at&.to_f,
              settings_fingerprint,
            ].join("\0"),
          ),
        }
      end
    end

    def start_session(database, account_id, fingerprint)
      session = ::LiveMetrics::PulsoidStreamingSession.new(
        database: database,
        account_id: account_id,
        fingerprint: fingerprint,
      )
      key = session_key(database, account_id)

      @sessions[key] = session if session.start
    rescue => e
      ::LiveMetrics::SafeLog.warn(
        "pulsoid_stream_session_start_failed",
        error: e,
        account_id: account_id,
      )
    end

    def stop_session(key, clear_state:)
      session = @sessions.delete(key)
      return if session.blank?

      session.request_stop
      session.join(3)
      remember_session_counters(session)
      registry.release_session(session.account_id, session.token)
      ::LiveMetrics::CurrentStateStore.delete(session.account_id) if clear_state
    rescue => e
      ::LiveMetrics::SafeLog.warn(
        "pulsoid_stream_session_stop_failed",
        error: e,
        account_id: session&.account_id,
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

        remember_session_counters(session)
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
          remember_session_counters(session)
          registry.release_session(session.account_id, session.token)
          ::LiveMetrics::CurrentStateStore.delete(session.account_id) if clear_state
        end
      rescue
        nil
      end
      @sessions.clear
    end

    def join_sessions(sessions, total_timeout:)
      deadline = monotonic_now + total_timeout.to_f
      sessions.each do |session|
        remaining = deadline - monotonic_now
        break if remaining <= 0

        session.join(remaining)
      end
    end

    def publish_health(database)
      sessions = session_keys_for(database).filter_map { |key| @sessions[key] }
      event_ages = sessions.filter_map(&:last_event_age_seconds)
      frame_ages = sessions.filter_map(&:last_frame_age_seconds)
      remember_latest_metadata(database, sessions)
      totals = @counter_totals[database.to_s]

      registry.publish_health(
        collector_started_at_ms: @collector_started_at_ms,
        desired_sessions: @desired_counts[database.to_s].to_i,
        sessions: sessions.count,
        connected: sessions.count(&:connected?),
        reconnecting: sessions.count(&:reconnecting?),
        unauthorized: sessions.count(&:unauthorized?),
        subscription_required: sessions.count(&:subscription_required?),
        scope_required: sessions.count(&:scope_required?),
        stalled: sessions.count(&:stalled?),
        oldest_event_age_seconds: event_ages.max,
        oldest_frame_age_seconds: frame_ages.max,
        frames: totals[:frames] + sessions.sum(&:frame_count),
        readings: totals[:readings] + sessions.sum(&:reading_count),
        reconnects: totals[:reconnects] + sessions.sum(&:reconnect_count),
        authorization_failures:
          totals[:authorization_failures] + sessions.sum(&:authorization_failure_count),
        limit: max_streams,
        limit_reached: @limit_reached[database.to_s] == true,
        last_reconnect_reason: @last_reconnect_events[database.to_s]&.last || "none",
        last_reconnect_at_ms: @last_reconnect_events[database.to_s]&.first,
        last_successful_join_at_ms: @last_successful_joins[database.to_s],
      )
    end

    def remember_latest_metadata(database, sessions)
      database = database.to_s
      reconnect =
        sessions.filter_map do |session|
          at = session.last_reconnect_at_ms
          next if at.blank?

          [at, session.last_reconnect_reason]
        end.max_by(&:first)
      if reconnect.present? &&
           (@last_reconnect_events[database].blank? || reconnect.first >= @last_reconnect_events[database].first)
        @last_reconnect_events[database] = reconnect
      end

      join_at = sessions.filter_map(&:last_successful_join_at_ms).max
      if join_at.present? && join_at >= @last_successful_joins.fetch(database, 0).to_i
        @last_successful_joins[database] = join_at
      end
    end

    def remember_session_counters(session)
      totals = @counter_totals[session.database.to_s]
      totals[:frames] += session.frame_count
      totals[:readings] += session.reading_count
      totals[:reconnects] += session.reconnect_count
      totals[:authorization_failures] += session.authorization_failure_count

      reconnect_at = session.last_reconnect_at_ms
      if reconnect_at.present? &&
           (@last_reconnect_events[session.database.to_s].blank? ||
             reconnect_at >= @last_reconnect_events[session.database.to_s].first)
        @last_reconnect_events[session.database.to_s] = [reconnect_at, session.last_reconnect_reason]
      end

      join_at = session.last_successful_join_at_ms
      if join_at.present? && join_at >= @last_successful_joins.fetch(session.database.to_s, 0).to_i
        @last_successful_joins[session.database.to_s] = join_at
      end
    end

    def empty_counter_totals
      { frames: 0, readings: 0, reconnects: 0, authorization_failures: 0 }
    end

    def ensure_leader(database)
      token = (@leader_tokens[database.to_s] ||= SecureRandom.hex(16))
      registry.acquire_or_renew_leader(token)
    end

    def lose_leadership(database)
      stop_database_sessions(database, clear_state: false)
      @leader_tokens.delete(database.to_s)
      clear_database_health_metadata(database)
    end

    def release_leader(database)
      token = @leader_tokens.delete(database.to_s)
      registry.release_leader(token) if token.present?
    end

    def release_all_leaders
      @leader_tokens.keys.each do |database|
        with_database(database) { release_leader(database) }
      rescue
        nil
      end
    end

    def clear_database_health_metadata(database)
      database = database.to_s
      @limit_reached.delete(database)
      @limit_event_logged.delete(database)
      @overflow_logged.delete(database)
      @desired_counts.delete(database)
    end

    def max_streams
      value = SiteSetting.live_metrics_pulsoid_max_streams.to_i
      value = 100 if value <= 0
      value.clamp(1, 500)
    end

    def log_overflow_once(overflow, limit)
      database = current_database
      unless overflow
        @overflow_logged.delete(database)
        return
      end
      return if @overflow_logged[database] == limit

      @overflow_logged[database] = limit
      ::LiveMetrics::SafeLog.warn(
        "pulsoid_stream_limit_reached",
        limit: limit,
        database: database,
      )
    end

    def log_limit_reached_once(limit_reached, limit)
      database = current_database
      unless limit_reached
        @limit_event_logged.delete(database)
        return
      end
      return if @limit_event_logged[database] == limit

      @limit_event_logged[database] = limit
      ::LiveMetrics::AdminEventLog.record(
        provider: "pulsoid",
        event: "stream_capacity",
        result: "limit_reached",
        severity: "warning",
        client_context: "server",
      )
    end

    def session_keys_for(database)
      @sessions.keys.select { |key| key.first == database.to_s }
    end

    def session_key(database, account_id)
      [database.to_s, account_id.to_i]
    end

    def registry
      ::LiveMetrics::PulsoidStreamingRegistry
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

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def current_time_ms
      (Time.now.to_f * 1000).to_i
    end
  end
end
