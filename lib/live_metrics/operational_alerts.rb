# frozen_string_literal: true

module ::LiveMetrics
  class OperationalAlerts
    AUTHORIZATION_WINDOW = 30.minutes
    AUTHORIZATION_FAILURE_THRESHOLD = 3
    RECONNECT_WINDOW = 30.minutes
    MINIMUM_RECONNECT_THRESHOLD = 8

    ISSUE_ORDER = %i[
      collector_health_stale
      stream_limit_reached
      repeated_authorization_failures
      repeated_stream_reconnects
    ].freeze

    class << self
      def issues(now: Time.zone.now)
        return [] unless SiteSetting.live_metrics_enabled

        health = ::LiveMetrics::AdminHealth.summary
        detected = []

        detect_collector_health!(detected, health)
        detect_stream_limit!(detected, health)
        detect_authorization_failures!(detected, now)
        detect_reconnects!(detected, health, now)

        detected.sort_by { |issue| ISSUE_ORDER.index(issue[:code]) || ISSUE_ORDER.length }
      rescue => e
        ::LiveMetrics::SafeLog.warn("operational_alert_evaluation_failed", error: e)
        []
      end

      private

      def detect_collector_health!(detected, health)
        configuration = health.fetch(:configuration, {})
        accounts = health.fetch(:accounts, {})
        collector = health.fetch(:collector, {})

        return unless configuration[:hyperate_streaming_operational]
        return unless accounts[:available] && accounts[:active_hyperate].to_i.positive?

        age = collector[:age_seconds]
        critical_age = ::LiveMetrics::AdminHealth::HEALTH_CRITICAL_AGE_SECONDS
        return if collector[:available] && age.present? && age.to_i < critical_age

        detected << {
          code: :collector_health_stale,
          values: {
            age_seconds: age&.to_i,
            critical_age_seconds: critical_age,
          },
        }
      end

      def detect_stream_limit!(detected, health)
        collector = health.fetch(:collector, {})
        return unless collector[:expected] && collector[:limit_reached]

        detected << {
          code: :stream_limit_reached,
          values: {
            sessions: collector[:sessions].to_i,
            limit: collector[:limit].to_i,
          },
        }
      end

      def detect_authorization_failures!(detected, now)
        count = ::LiveMetrics::AdminEventLog.count_since(
          since: now - AUTHORIZATION_WINDOW,
          result: "authorization_failed",
          severity: "error",
        )
        return if count < AUTHORIZATION_FAILURE_THRESHOLD

        detected << {
          code: :repeated_authorization_failures,
          values: {
            count: count,
            window_minutes: AUTHORIZATION_WINDOW.to_i / 60,
          },
        }
      end

      def detect_reconnects!(detected, health, now)
        configuration = health.fetch(:configuration, {})
        accounts = health.fetch(:accounts, {})
        collector = health.fetch(:collector, {})

        return unless configuration[:hyperate_streaming_operational]
        return unless accounts[:available] && accounts[:active_hyperate].to_i.positive?

        session_count = [collector[:sessions].to_i, 1].max
        threshold = [MINIMUM_RECONNECT_THRESHOLD, session_count * 2].max

        count = ::LiveMetrics::AdminEventLog.count_since(
          since: now - RECONNECT_WINDOW,
          provider: "hyperate",
          event: "stream_reconnect",
          severity: %w[warning error],
          exclude_result: "authorization_failed",
        )
        return if count < threshold

        detected << {
          code: :repeated_stream_reconnects,
          values: {
            count: count,
            threshold: threshold,
            window_minutes: RECONNECT_WINDOW.to_i / 60,
          },
        }
      end
    end
  end
end
