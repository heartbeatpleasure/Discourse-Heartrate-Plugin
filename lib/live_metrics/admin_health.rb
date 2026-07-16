# frozen_string_literal: true

require "json"

module ::LiveMetrics
  class AdminHealth
    HEALTH_WARNING_AGE_SECONDS = 5
    HEALTH_CRITICAL_AGE_SECONDS = ::LiveMetrics::HypeRateStreamingRegistry::HEALTH_TTL_SECONDS
    PULSOID_HEALTH_CRITICAL_AGE_SECONDS = ::LiveMetrics::PulsoidStreamingRegistry::HEALTH_TTL_SECONDS

    class << self
      def summary
        generated_at = Time.zone.now
        configuration = configuration_payload
        accounts = account_counts
        collectors = {
          hyperate: hyperate_collector_payload(generated_at, configuration),
          pulsoid: pulsoid_collector_payload(generated_at, configuration),
        }
        warnings = build_warnings(configuration, accounts, collectors)
        overall = overall_payload(configuration, warnings, collectors)

        {
          generated_at: generated_at.iso8601,
          overall: overall,
          warnings: warnings,
          # Backwards-compatible alias used by the pre-Iteration 11 admin page
          # and any external diagnostics that still expect HypeRate here.
          collector: collectors[:hyperate],
          collectors: collectors,
          accounts: accounts,
          configuration: configuration,
          storage: storage_payload,
          privacy: {
            bpm_values_included: false,
            personal_identifiers_included: false,
            provider_credentials_included: false,
          },
        }
      end

      private

      def configuration_payload
        {
          plugin_enabled: setting_enabled?(:live_metrics_enabled),
          async_current_readings_enabled: setting_enabled?(:live_metrics_async_current_readings_enabled),
          pulsoid_enabled: setting_enabled?(:live_metrics_pulsoid_enabled),
          pulsoid_streaming_setting_enabled: setting_enabled?(:live_metrics_pulsoid_streaming_enabled),
          pulsoid_client_configured: ::LiveMetrics::PulsoidClient.configured?,
          pulsoid_streaming_operational: ::LiveMetrics::RefreshCoordinator.pulsoid_streaming_enabled?,
          pulsoid_max_streams: integer_setting(:live_metrics_pulsoid_max_streams),
          pulsoid_stream_transport_timeout_seconds: integer_setting(
            :live_metrics_pulsoid_stream_transport_timeout_seconds,
          ),
          hyperate_enabled: setting_enabled?(:live_metrics_hyperate_enabled),
          hyperate_streaming_setting_enabled: setting_enabled?(:live_metrics_hyperate_streaming_enabled),
          hyperate_client_configured: ::LiveMetrics::HypeRateClient.configured?,
          hyperate_streaming_operational: ::LiveMetrics::RefreshCoordinator.hyperate_streaming_enabled?,
          hyperate_max_streams: integer_setting(:live_metrics_hyperate_max_streams),
          hyperate_stream_stall_timeout_seconds: integer_setting(
            :live_metrics_hyperate_stream_stall_timeout_seconds,
          ),
          frontend_poll_interval_seconds: integer_setting(:live_metrics_poll_interval_seconds),
          provider_refresh_interval_seconds: integer_setting(
            :live_metrics_provider_refresh_interval_seconds,
          ),
          live_threshold_seconds: integer_setting(:live_metrics_live_threshold_seconds),
          stale_threshold_seconds: integer_setting(:live_metrics_stale_threshold_seconds),
        }
      rescue => e
        ::LiveMetrics::SafeLog.warn("admin_health_configuration_failed", error: e)
        empty_configuration_payload
      end

      def empty_configuration_payload
        {
          plugin_enabled: false,
          async_current_readings_enabled: false,
          pulsoid_enabled: false,
          pulsoid_streaming_setting_enabled: false,
          pulsoid_client_configured: false,
          pulsoid_streaming_operational: false,
          pulsoid_max_streams: 0,
          pulsoid_stream_transport_timeout_seconds: 0,
          hyperate_enabled: false,
          hyperate_streaming_setting_enabled: false,
          hyperate_client_configured: false,
          hyperate_streaming_operational: false,
          hyperate_max_streams: 0,
          hyperate_stream_stall_timeout_seconds: 0,
          frontend_poll_interval_seconds: 0,
          provider_refresh_interval_seconds: 0,
          live_threshold_seconds: 0,
          stale_threshold_seconds: 0,
        }
      end

      def account_counts
        return unavailable_account_counts unless provider_accounts_table_ready?

        grouped = ::LiveMetrics::ProviderAccount.active.group(:provider).count
        hyperate = grouped.fetch(::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE, 0).to_i
        pulsoid = grouped.fetch(::LiveMetrics::ProviderAccount::PROVIDER_PULSOID, 0).to_i

        {
          available: true,
          active_total: hyperate + pulsoid,
          active_hyperate: hyperate,
          active_pulsoid: pulsoid,
        }
      rescue => e
        ::LiveMetrics::SafeLog.warn("admin_health_account_counts_failed", error: e)
        unavailable_account_counts
      end

      def unavailable_account_counts
        {
          available: false,
          active_total: 0,
          active_hyperate: 0,
          active_pulsoid: 0,
        }
      end

      def hyperate_collector_payload(now, configuration)
        raw = ::LiveMetrics::HypeRateStreamingRegistry.read_health
        return empty_collector_payload(
          provider: :hyperate,
          expected: configuration[:hyperate_streaming_operational],
          limit: configuration[:hyperate_max_streams],
        ) if raw.blank?

        base_collector_payload(
          raw,
          now: now,
          provider: :hyperate,
          expected: configuration[:hyperate_streaming_operational],
          limit: configuration[:hyperate_max_streams],
          reconnect_reason: ::LiveMetrics::HypeRateStreamingRegistry.sanitize_reconnect_reason(
            raw["last_reconnect_reason"],
          ),
          join_result: ::LiveMetrics::HypeRateStreamingRegistry.sanitize_join_result(
            raw["last_join_result"],
          ),
        ).merge(
          desired_sessions: raw["sessions"].to_i,
          subscription_required: 0,
          scope_required: 0,
          authorization_failures: raw["unauthorized"].to_i,
          stalls: raw["stalls"].to_i,
        )
      rescue => e
        ::LiveMetrics::SafeLog.warn("admin_health_hyperate_collector_parse_failed", error: e)
        empty_collector_payload(
          provider: :hyperate,
          expected: configuration[:hyperate_streaming_operational],
          limit: configuration[:hyperate_max_streams],
        )
      end

      def pulsoid_collector_payload(now, configuration)
        raw = ::LiveMetrics::PulsoidStreamingRegistry.read_health
        return empty_collector_payload(
          provider: :pulsoid,
          expected: configuration[:pulsoid_streaming_operational],
          limit: configuration[:pulsoid_max_streams],
        ) if raw.blank?

        last_successful_join_at = time_from_ms(raw["last_successful_join_at_ms"])
        base_collector_payload(
          raw,
          now: now,
          provider: :pulsoid,
          expected: configuration[:pulsoid_streaming_operational],
          limit: configuration[:pulsoid_max_streams],
          reconnect_reason: ::LiveMetrics::PulsoidStreamingRegistry.sanitize_reconnect_reason(
            raw["last_reconnect_reason"],
          ),
          join_result: last_successful_join_at.present? ? "successful" : "none",
        ).merge(
          desired_sessions: raw["desired_sessions"].to_i,
          subscription_required: raw["subscription_required"].to_i,
          scope_required: raw["scope_required"].to_i,
          authorization_failures: raw["authorization_failures"].to_i,
          stalls: 0,
        )
      rescue => e
        ::LiveMetrics::SafeLog.warn("admin_health_pulsoid_collector_parse_failed", error: e)
        empty_collector_payload(
          provider: :pulsoid,
          expected: configuration[:pulsoid_streaming_operational],
          limit: configuration[:pulsoid_max_streams],
        )
      end

      def base_collector_payload(raw, now:, provider:, expected:, limit:, reconnect_reason:, join_result:)
        updated_at_ms = positive_integer(raw["updated_at_ms"])
        age_seconds =
          if updated_at_ms.present?
            [((now.to_f * 1000).to_i - updated_at_ms) / 1000, 0].max
          end

        {
          provider: provider.to_s,
          expected: expected,
          available: true,
          version: raw["v"].to_i,
          updated_at: time_from_ms(updated_at_ms),
          age_seconds: age_seconds,
          collector_started_at: time_from_ms(raw["collector_started_at_ms"]),
          sessions: raw["sessions"].to_i,
          connected: raw["connected"].to_i,
          reconnecting: raw["reconnecting"].to_i,
          unauthorized: raw["unauthorized"].to_i,
          stalled: raw["stalled"].to_i,
          oldest_event_age_seconds: nullable_integer(raw["oldest_event_age_seconds"]),
          oldest_frame_age_seconds: nullable_integer(raw["oldest_frame_age_seconds"]),
          frames: raw["frames"].to_i,
          readings: raw["readings"].to_i,
          reconnects: raw["reconnects"].to_i,
          limit: positive_integer(raw["limit"]) || limit.to_i,
          limit_reached: raw["limit_reached"] == true,
          last_reconnect_reason: reconnect_reason,
          last_reconnect_at: time_from_ms(raw["last_reconnect_at_ms"]),
          last_join_result: join_result,
          last_successful_join_at: time_from_ms(raw["last_successful_join_at_ms"]),
        }
      end

      def empty_collector_payload(provider:, expected:, limit:)
        {
          provider: provider.to_s,
          expected: expected,
          available: false,
          version: nil,
          updated_at: nil,
          age_seconds: nil,
          collector_started_at: nil,
          desired_sessions: 0,
          sessions: 0,
          connected: 0,
          reconnecting: 0,
          unauthorized: 0,
          subscription_required: 0,
          scope_required: 0,
          stalled: 0,
          oldest_event_age_seconds: nil,
          oldest_frame_age_seconds: nil,
          frames: 0,
          readings: 0,
          reconnects: 0,
          authorization_failures: 0,
          stalls: 0,
          limit: limit.to_i,
          limit_reached: false,
          last_reconnect_reason: "none",
          last_reconnect_at: nil,
          last_join_result: "none",
          last_successful_join_at: nil,
        }
      end

      def build_warnings(configuration, accounts, collectors)
        warnings = []

        unless configuration[:plugin_enabled]
          warnings << warning(:plugin_disabled, :info)
          return warnings
        end

        warnings.concat(
          hyperate_warnings(configuration, accounts, collectors.fetch(:hyperate)),
        )
        warnings.concat(
          pulsoid_warnings(configuration, accounts, collectors.fetch(:pulsoid)),
        )
        warnings
      end

      def hyperate_warnings(configuration, accounts, collector)
        warnings = []
        if configuration[:hyperate_streaming_setting_enabled] &&
             !configuration[:async_current_readings_enabled]
          warnings << warning(:async_disabled, :warning)
        end
        if configuration[:hyperate_streaming_setting_enabled] && !configuration[:hyperate_enabled]
          warnings << warning(:hyperate_disabled, :warning)
        end
        if configuration[:hyperate_streaming_setting_enabled] &&
             configuration[:hyperate_enabled] &&
             !configuration[:hyperate_client_configured]
          warnings << warning(:hyperate_not_configured, :warning)
        end

        return warnings unless collector[:expected]

        warnings.concat(
          collector_runtime_warnings(
            collector,
            prefix: nil,
            critical_age_seconds: HEALTH_CRITICAL_AGE_SECONDS,
            active_accounts: accounts[:active_hyperate],
          ),
        )
        warnings
      end

      def pulsoid_warnings(configuration, accounts, collector)
        warnings = []
        if configuration[:pulsoid_streaming_setting_enabled] &&
             !configuration[:async_current_readings_enabled]
          warnings << warning(:pulsoid_async_disabled, :warning)
        end
        if configuration[:pulsoid_streaming_setting_enabled] && !configuration[:pulsoid_enabled]
          warnings << warning(:pulsoid_disabled, :warning)
        end
        if configuration[:pulsoid_streaming_setting_enabled] &&
             configuration[:pulsoid_enabled] &&
             !configuration[:pulsoid_client_configured]
          warnings << warning(:pulsoid_not_configured, :warning)
        end

        return warnings unless collector[:expected]

        warnings.concat(
          collector_runtime_warnings(
            collector,
            prefix: :pulsoid,
            critical_age_seconds: PULSOID_HEALTH_CRITICAL_AGE_SECONDS,
            active_accounts: accounts[:active_pulsoid],
          ),
        )
        if collector[:subscription_required].positive?
          warnings << warning(
            :pulsoid_subscription_required_sessions,
            :warning,
            count: collector[:subscription_required],
          )
        end
        if collector[:scope_required].positive?
          warnings << warning(
            :pulsoid_scope_required_sessions,
            :critical,
            count: collector[:scope_required],
          )
        end
        warnings
      end

      def collector_runtime_warnings(collector, prefix:, critical_age_seconds:, active_accounts:)
        warnings = []
        code = ->(suffix) { [prefix, suffix].compact.join("_").to_sym }

        unless collector[:available]
          warnings << warning(
            code.call(:collector_health_missing),
            :critical,
            critical_age_seconds: critical_age_seconds,
          )
          return warnings
        end

        if collector[:age_seconds].to_i >= critical_age_seconds
          warnings << warning(
            code.call(:collector_health_critical),
            :critical,
            age_seconds: collector[:age_seconds].to_i,
            critical_age_seconds: critical_age_seconds,
          )
        elsif collector[:age_seconds].to_i >= HEALTH_WARNING_AGE_SECONDS
          warnings << warning(
            code.call(:collector_health_stale),
            :warning,
            age_seconds: collector[:age_seconds].to_i,
            warning_age_seconds: HEALTH_WARNING_AGE_SECONDS,
          )
        end

        if collector[:limit_reached]
          warnings << warning(
            code.call(:stream_limit_reached),
            :warning,
            sessions: collector[:sessions],
            limit: collector[:limit],
          )
        end
        if collector[:stalled].positive?
          warnings << warning(code.call(:stalled_sessions), :critical, count: collector[:stalled])
        end
        if collector[:unauthorized].positive?
          warnings << warning(
            code.call(:unauthorized_sessions),
            :critical,
            count: collector[:unauthorized],
          )
        end
        if collector[:reconnecting].positive?
          warnings << warning(
            code.call(:reconnecting_sessions),
            :warning,
            count: collector[:reconnecting],
          )
        end
        if active_accounts.to_i.positive? && collector[:sessions].zero?
          warnings << warning(
            code.call(:active_accounts_without_sessions),
            :warning,
            count: active_accounts.to_i,
          )
        end
        warnings
      end

      def warning(code, severity, values = {})
        {
          code: code.to_s,
          severity: severity.to_s,
          values: values,
        }
      end

      def overall_payload(configuration, warnings, collectors)
        highest = warnings.max_by { |entry| severity_rank(entry[:severity]) }

        if highest.present? && highest[:severity] == "critical"
          { state: "critical", severity: "critical" }
        elsif highest.present? && highest[:severity] == "warning"
          { state: "attention", severity: "warning" }
        elsif collectors.values.any? { |collector| collector[:expected] }
          { state: "healthy", severity: "ok" }
        elsif configuration[:plugin_enabled]
          { state: "inactive", severity: "info" }
        else
          { state: "inactive", severity: "info" }
        end
      end

      def severity_rank(value)
        case value.to_s
        when "critical"
          3
        when "warning"
          2
        when "info"
          1
        else
          0
        end
      end

      def storage_payload
        {
          current_state_mode: "latest_only_redis",
          current_state_ttl_seconds: ::LiveMetrics::CurrentStateStore.ttl_seconds,
          historical_reading_storage: false,
          health_payload_mode: "aggregate_operational_only",
        }
      rescue
        {
          current_state_mode: "latest_only_redis",
          current_state_ttl_seconds: nil,
          historical_reading_storage: false,
          health_payload_mode: "aggregate_operational_only",
        }
      end

      def setting_enabled?(name)
        SiteSetting.respond_to?(name) && !!SiteSetting.public_send(name)
      rescue
        false
      end

      def integer_setting(name)
        return 0 unless SiteSetting.respond_to?(name)

        SiteSetting.public_send(name).to_i
      rescue
        0
      end

      def nullable_integer(value)
        return nil if value.nil?

        value.to_i
      end

      def positive_integer(value)
        integer = value.to_i
        integer.positive? ? integer : nil
      end

      def time_from_ms(value)
        milliseconds = positive_integer(value)
        return nil if milliseconds.blank?

        Time.zone.at(milliseconds / 1000.0).iso8601
      rescue
        nil
      end

      def provider_accounts_table_ready?
        ::LiveMetrics::ProviderAccount.table_exists? &&
          %w[provider active].all? do |column|
            ::LiveMetrics::ProviderAccount.column_names.include?(column)
          end
      rescue
        false
      end
    end
  end
end
