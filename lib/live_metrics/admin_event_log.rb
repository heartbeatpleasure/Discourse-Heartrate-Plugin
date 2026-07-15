# frozen_string_literal: true

require "json"
require "securerandom"

module ::LiveMetrics
  class AdminEventLog
    KEY = "live_metrics:admin_events:v1"
    VERSION = 1
    MAX_EVENTS = 500
    RETENTION_SECONDS = 7.days.to_i
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 200

    PROVIDERS = %w[pulsoid hyperate system].freeze
    SEVERITIES = %w[info warning error].freeze
    CLIENT_CONTEXTS = %w[desktop_browser mobile_browser embedded_webview server unknown].freeze
    EVENTS = %w[
      oauth_start
      oauth_callback
      provider_connect
      provider_disconnect
      provider_refresh
      stream_join
      stream_reconnect
      stream_capacity
      unknown
    ].freeze
    RESULTS = %w[
      redirected
      success
      disconnected
      recovered
      sharing_denied
      not_configured
      state_mismatch
      provider_error
      missing_authorization_code
      database_not_ready
      connect_failed
      disconnect_failed
      invalid_device_id
      disabled
      authorization_failed
      transport_stalled
      no_data
      transport_error
      unexpected_error
      stream_ended
      start_failed
      limit_reached
      unknown
    ].freeze

    class << self
      def record(
        provider:,
        event:,
        result:,
        severity: :info,
        client_context: :server,
        occurred_at: Time.zone.now
      )
        occurred_at = occurred_at.in_time_zone
        payload = {
          v: VERSION,
          id: SecureRandom.hex(8),
          occurred_at: occurred_at.iso8601(3),
          occurred_at_ms: (occurred_at.to_f * 1000).to_i,
          severity: sanitize_severity(severity),
          provider: sanitize_provider(provider),
          event: sanitize_event(event),
          result: sanitize_result(result),
          client_context: sanitize_client_context(client_context),
        }

        redis.zadd(KEY, occurred_at.to_f, JSON.generate(payload))
        prune!
        true
      rescue => e
        Rails.logger.warn(
          "[live_metrics] admin event log write failed error=#{e.class}: #{e.message}",
        )
        false
      end

      def recent(provider: nil, severity: nil, limit: DEFAULT_LIMIT)
        prune!
        provider = sanitize_filter(provider, PROVIDERS)
        severity = sanitize_filter(severity, SEVERITIES)
        limit = normalize_limit(limit)

        redis
          .zrevrange(KEY, 0, -1)
          .filter_map { |entry| parse_entry(entry) }
          .select { |entry| provider.blank? || entry[:provider] == provider }
          .select { |entry| severity.blank? || entry[:severity] == severity }
          .first(limit)
      rescue => e
        Rails.logger.warn(
          "[live_metrics] admin event log read failed error=#{e.class}: #{e.message}",
        )
        []
      end

      def total_count
        prune!
        redis.zcard(KEY).to_i
      rescue
        0
      end

      def clear
        redis.del(KEY)
      rescue
        false
      end

      def client_context_for(request)
        user_agent = request&.user_agent.to_s
        return "unknown" if user_agent.blank?

        normalized = user_agent.downcase
        if embedded_webview?(normalized)
          "embedded_webview"
        elsif normalized.match?(/mobile|android|iphone|ipad|ipod/)
          "mobile_browser"
        else
          "desktop_browser"
        end
      rescue
        "unknown"
      end

      private

      def prune!
        cutoff = Time.now.to_f - RETENTION_SECONDS
        redis.zremrangebyscore(KEY, 0, cutoff)

        count = redis.zcard(KEY).to_i
        if count > MAX_EVENTS
          redis.zremrangebyrank(KEY, 0, count - MAX_EVENTS - 1)
        end

        redis.expire(KEY, RETENTION_SECONDS)
      end

      def parse_entry(serialized)
        raw = JSON.parse(serialized.to_s)
        occurred_at_ms = raw["occurred_at_ms"].to_i
        return nil if occurred_at_ms <= 0

        {
          id: raw["id"].to_s.presence || SecureRandom.hex(8),
          occurred_at: raw["occurred_at"].to_s,
          occurred_at_ms: occurred_at_ms,
          severity: sanitize_severity(raw["severity"]),
          provider: sanitize_provider(raw["provider"]),
          event: sanitize_event(raw["event"]),
          result: sanitize_result(raw["result"]),
          client_context: sanitize_client_context(raw["client_context"]),
        }
      rescue JSON::ParserError, TypeError
        nil
      end

      def embedded_webview?(normalized_user_agent)
        normalized_user_agent.match?(
          /discoursehub|; wv\)|\bwv\b|fban|fbav|instagram|snapchat|micromessenger|line\//,
        ) ||
          normalized_user_agent.match?(/(iphone|ipad|ipod).*applewebkit(?!.*safari)/)
      end

      def normalize_limit(value)
        value = value.to_i
        value = DEFAULT_LIMIT if value <= 0
        value.clamp(1, MAX_LIMIT)
      end

      def sanitize_filter(value, allowed)
        normalized = value.to_s
        allowed.include?(normalized) ? normalized : nil
      end

      def sanitize_provider(value)
        normalized = value.to_s
        PROVIDERS.include?(normalized) ? normalized : "system"
      end

      def sanitize_severity(value)
        normalized = value.to_s
        SEVERITIES.include?(normalized) ? normalized : "info"
      end

      def sanitize_client_context(value)
        normalized = value.to_s
        CLIENT_CONTEXTS.include?(normalized) ? normalized : "unknown"
      end

      def sanitize_event(value)
        normalized = value.to_s
        EVENTS.include?(normalized) ? normalized : "unknown"
      end

      def sanitize_result(value)
        normalized = value.to_s
        RESULTS.include?(normalized) ? normalized : "unknown"
      end

      def redis
        Discourse.redis
      end
    end
  end
end
