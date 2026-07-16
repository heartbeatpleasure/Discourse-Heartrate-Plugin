# frozen_string_literal: true

module ::LiveMetrics
  class OperationalAlerts
    AUTHORIZATION_WINDOW = 30.minutes
    AUTHORIZATION_FAILURE_THRESHOLD = 3
    SUBSCRIPTION_WINDOW = 30.minutes
    SUBSCRIPTION_REQUIRED_THRESHOLD = 3
    SCOPE_WINDOW = 30.minutes
    SCOPE_REQUIRED_THRESHOLD = 2
    RECONNECT_WINDOW = 30.minutes
    MINIMUM_RECONNECT_THRESHOLD = 8

    ISSUE_ORDER = %i[
      collector_health_stale
      pulsoid_collector_health_stale
      stream_limit_reached
      pulsoid_stream_limit_reached
      repeated_authorization_failures
      pulsoid_repeated_authorization_failures
      pulsoid_subscription_required
      pulsoid_scope_required
      repeated_stream_reconnects
      pulsoid_repeated_stream_reconnects
    ].freeze

    class << self
      def issues(now: Time.zone.now)
        return [] unless SiteSetting.live_metrics_enabled

        health = ::LiveMetrics::AdminHealth.summary
        detected = []

        detect_provider_collector_issues!(detected, health, provider: :hyperate)
        detect_provider_collector_issues!(detected, health, provider: :pulsoid)
        detect_authorization_failures!(detected, health, now, provider: :hyperate)
        detect_authorization_failures!(detected, health, now, provider: :pulsoid)
        detect_pulsoid_entitlement_failures!(detected, health, now)
        detect_reconnects!(detected, health, now, provider: :hyperate)
        detect_reconnects!(detected, health, now, provider: :pulsoid)

        detected.sort_by { |issue| ISSUE_ORDER.index(issue[:code]) || ISSUE_ORDER.length }
      rescue => e
        ::LiveMetrics::SafeLog.warn("operational_alert_evaluation_failed", error: e)
        []
      end

      private

      def detect_provider_collector_issues!(detected, health, provider:)
        configuration = health.fetch(:configuration, {})
        accounts = health.fetch(:accounts, {})
        collector = collector_for(health, provider)
        return unless provider_streaming_operational?(configuration, provider)
        return unless active_account_count(accounts, provider).positive?

        age = collector[:age_seconds]
        critical_age = critical_health_age(provider)
        unless collector[:available] && age.present? && age.to_i < critical_age
          detected << {
            code: issue_code(provider, :collector_health_stale),
            values: {
              age_seconds: age&.to_i,
              critical_age_seconds: critical_age,
            },
          }
        end

        if collector[:limit_reached]
          detected << {
            code: issue_code(provider, :stream_limit_reached),
            values: {
              sessions: collector[:sessions].to_i,
              limit: collector[:limit].to_i,
            },
          }
        end
      end

      def detect_authorization_failures!(detected, health, now, provider:)
        configuration = health.fetch(:configuration, {})
        accounts = health.fetch(:accounts, {})
        return unless provider_streaming_operational?(configuration, provider)
        return unless active_account_count(accounts, provider).positive?

        count = ::LiveMetrics::AdminEventLog.count_since(
          since: now - AUTHORIZATION_WINDOW,
          provider: provider.to_s,
          result: "authorization_failed",
          severity: "error",
        )
        return if count < AUTHORIZATION_FAILURE_THRESHOLD

        detected << {
          code: issue_code(provider, :repeated_authorization_failures),
          values: {
            count: count,
            window_minutes: AUTHORIZATION_WINDOW.to_i / 60,
          },
        }
      end

      def detect_pulsoid_entitlement_failures!(detected, health, now)
        configuration = health.fetch(:configuration, {})
        accounts = health.fetch(:accounts, {})
        return unless provider_streaming_operational?(configuration, :pulsoid)
        return unless active_account_count(accounts, :pulsoid).positive?

        subscription_count = ::LiveMetrics::AdminEventLog.count_since(
          since: now - SUBSCRIPTION_WINDOW,
          provider: "pulsoid",
          result: "subscription_required",
          severity: %w[warning error],
        )
        if subscription_count >= SUBSCRIPTION_REQUIRED_THRESHOLD
          detected << {
            code: :pulsoid_subscription_required,
            values: {
              count: subscription_count,
              window_minutes: SUBSCRIPTION_WINDOW.to_i / 60,
            },
          }
        end

        scope_count = ::LiveMetrics::AdminEventLog.count_since(
          since: now - SCOPE_WINDOW,
          provider: "pulsoid",
          result: "scope_required",
          severity: %w[warning error],
        )
        if scope_count >= SCOPE_REQUIRED_THRESHOLD
          detected << {
            code: :pulsoid_scope_required,
            values: {
              count: scope_count,
              window_minutes: SCOPE_WINDOW.to_i / 60,
            },
          }
        end
      end

      def detect_reconnects!(detected, health, now, provider:)
        configuration = health.fetch(:configuration, {})
        accounts = health.fetch(:accounts, {})
        collector = collector_for(health, provider)
        return unless provider_streaming_operational?(configuration, provider)
        return unless active_account_count(accounts, provider).positive?

        session_count = [collector[:sessions].to_i, 1].max
        threshold = [MINIMUM_RECONNECT_THRESHOLD, session_count * 2].max
        count = ::LiveMetrics::AdminEventLog.count_since(
          since: now - RECONNECT_WINDOW,
          provider: provider.to_s,
          event: "stream_reconnect",
          severity: %w[warning error],
          exclude_result: ["authorization_failed", "subscription_required", "scope_required"],
        )
        return if count < threshold

        detected << {
          code: issue_code(provider, :repeated_stream_reconnects),
          values: {
            count: count,
            threshold: threshold,
            window_minutes: RECONNECT_WINDOW.to_i / 60,
          },
        }
      end

      def collector_for(health, provider)
        collectors = health.fetch(:collectors, {})
        collector = collectors[provider] || collectors[provider.to_s]
        return collector if collector.present?
        return health.fetch(:collector, {}) if provider.to_sym == :hyperate

        {}
      end

      def provider_streaming_operational?(configuration, provider)
        configuration["#{provider}_streaming_operational".to_sym] == true
      end

      def active_account_count(accounts, provider)
        accounts["active_#{provider}".to_sym].to_i
      end

      def critical_health_age(provider)
        provider.to_sym == :pulsoid ?
          ::LiveMetrics::AdminHealth::PULSOID_HEALTH_CRITICAL_AGE_SECONDS :
          ::LiveMetrics::AdminHealth::HEALTH_CRITICAL_AGE_SECONDS
      end

      def issue_code(provider, base)
        provider.to_sym == :pulsoid ? "pulsoid_#{base}".to_sym : base.to_sym
      end
    end
  end
end
