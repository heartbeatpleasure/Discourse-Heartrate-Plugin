import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

const RECONNECT_REASON_KEYS = new Set([
  "none",
  "stream_ended",
  "transport_stalled",
  "no_data",
  "transport_error",
  "authorization_failed",
  "unexpected_error",
  "unknown",
]);

const JOIN_RESULT_KEYS = new Set(["none", "successful"]);

function formatNumber(value) {
  const number = Number(value || 0);
  return Number.isFinite(number) ? new Intl.NumberFormat().format(number) : "0";
}

function formatDateTime(value) {
  if (!value) {
    return i18n("admin.live_metrics.health.not_available");
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return i18n("admin.live_metrics.health.not_available");
  }

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "medium",
  }).format(date);
}

function formatAge(value) {
  if (value === null || value === undefined || value === "") {
    return i18n("admin.live_metrics.health.not_available");
  }

  const seconds = Math.max(0, Number(value) || 0);
  if (seconds < 60) {
    return i18n("admin.live_metrics.health.seconds", {
      count: Math.round(seconds),
    });
  }

  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = Math.round(seconds % 60);
  return i18n("admin.live_metrics.health.minutes_seconds", {
    minutes,
    seconds: remainingSeconds,
  });
}

function enabledLabel(value) {
  return value
    ? i18n("admin.live_metrics.health.enabled")
    : i18n("admin.live_metrics.health.disabled");
}

function yesNoLabel(value) {
  return value
    ? i18n("admin.live_metrics.health.yes")
    : i18n("admin.live_metrics.health.no");
}

function severityBadgeClass(severity) {
  switch (String(severity || "ok")) {
    case "critical":
      return "is-critical";
    case "warning":
      return "is-warning";
    case "info":
      return "is-info";
    default:
      return "is-ok";
  }
}

function extractError(error) {
  return (
    error?.jqXHR?.responseJSON?.errors?.[0] ||
    error?.responseJSON?.errors?.[0] ||
    error?.message ||
    i18n("admin.live_metrics.health.load_error")
  );
}

export default class AdminPluginsLiveMetricsHealthController extends Controller {
  @tracked data = null;
  @tracked isLoading = false;
  @tracked error = null;

  resetState() {
    this.data = null;
    this.isLoading = false;
    this.error = null;
  }

  @action
  async loadHealth() {
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = null;

    try {
      this.data = await ajax("/admin/plugins/live-metrics/health.json");
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.isLoading = false;
    }
  }

  get hasData() {
    return Boolean(this.data);
  }

  get generatedAtLabel() {
    return formatDateTime(this.data?.generated_at);
  }

  get overallLabel() {
    const state = String(this.data?.overall?.state || "inactive");
    return i18n(`admin.live_metrics.health.overall.${state}.label`);
  }

  get overallDescription() {
    const state = String(this.data?.overall?.state || "inactive");
    return i18n(`admin.live_metrics.health.overall.${state}.description`);
  }

  get overallBadgeClass() {
    return severityBadgeClass(this.data?.overall?.severity);
  }

  get warningItems() {
    return (this.data?.warnings || []).map((warning) => {
      const code = String(warning?.code || "unknown");
      const values = warning?.values || {};
      return {
        code,
        severity: String(warning?.severity || "warning"),
        badgeClass: severityBadgeClass(warning?.severity),
        title: i18n(`admin.live_metrics.health.warnings.${code}.title`, values),
        description: i18n(
          `admin.live_metrics.health.warnings.${code}.description`,
          values
        ),
      };
    });
  }

  get hasWarnings() {
    return this.warningItems.length > 0;
  }

  get summaryCards() {
    const collector = this.data?.collector || {};
    const accounts = this.data?.accounts || {};
    const limit = Number(collector.limit || 0);
    const sessions = Number(collector.sessions || 0);
    const capacitySeverity = collector.limit_reached ? "warning" : "ok";
    const freshnessSeverity =
      collector.expected && !collector.available
        ? "critical"
        : Number(collector.age_seconds || 0) >= 5
          ? "warning"
          : collector.expected
            ? "ok"
            : "info";

    return [
      {
        label: i18n("admin.live_metrics.health.cards.collector.label"),
        value: collector.expected
          ? collector.available
            ? i18n("admin.live_metrics.health.cards.collector.running")
            : i18n("admin.live_metrics.health.cards.collector.unavailable")
          : i18n("admin.live_metrics.health.cards.collector.inactive"),
        detail: collector.available
          ? i18n("admin.live_metrics.health.cards.collector.updated", {
              age: formatAge(collector.age_seconds),
            })
          : i18n("admin.live_metrics.health.cards.collector.no_health"),
        badgeClass: severityBadgeClass(freshnessSeverity),
      },
      {
        label: i18n("admin.live_metrics.health.cards.sessions.label"),
        value: i18n("admin.live_metrics.health.cards.sessions.value", {
          connected: formatNumber(collector.connected),
          sessions: formatNumber(collector.sessions),
        }),
        detail: i18n("admin.live_metrics.health.cards.sessions.detail", {
          reconnecting: formatNumber(collector.reconnecting),
          stalled: formatNumber(collector.stalled),
          unauthorized: formatNumber(collector.unauthorized),
        }),
        badgeClass: severityBadgeClass(
          Number(collector.stalled || 0) > 0 ||
            Number(collector.unauthorized || 0) > 0
            ? "critical"
            : Number(collector.reconnecting || 0) > 0
              ? "warning"
              : "ok"
        ),
      },
      {
        label: i18n("admin.live_metrics.health.cards.capacity.label"),
        value: limit > 0 ? `${formatNumber(sessions)} / ${formatNumber(limit)}` : "—",
        detail: collector.limit_reached
          ? i18n("admin.live_metrics.health.cards.capacity.reached")
          : i18n("admin.live_metrics.health.cards.capacity.available"),
        badgeClass: severityBadgeClass(capacitySeverity),
      },
      {
        label: i18n("admin.live_metrics.health.cards.accounts.label"),
        value: accounts.available
          ? formatNumber(accounts.active_total)
          : i18n("admin.live_metrics.health.not_available"),
        detail: accounts.available
          ? i18n("admin.live_metrics.health.cards.accounts.detail", {
              hyperate: formatNumber(accounts.active_hyperate),
              pulsoid: formatNumber(accounts.active_pulsoid),
            })
          : i18n("admin.live_metrics.health.cards.accounts.unavailable"),
        badgeClass: severityBadgeClass(accounts.available ? "ok" : "warning"),
      },
    ];
  }

  get activityCards() {
    const collector = this.data?.collector || {};
    return [
      {
        label: i18n("admin.live_metrics.health.activity.frames"),
        value: formatNumber(collector.frames),
      },
      {
        label: i18n("admin.live_metrics.health.activity.readings"),
        value: formatNumber(collector.readings),
      },
      {
        label: i18n("admin.live_metrics.health.activity.reconnects"),
        value: formatNumber(collector.reconnects),
      },
      {
        label: i18n("admin.live_metrics.health.activity.stalls"),
        value: formatNumber(collector.stalls),
      },
    ];
  }

  get operationalRows() {
    const collector = this.data?.collector || {};
    const reconnectReason = RECONNECT_REASON_KEYS.has(
      String(collector.last_reconnect_reason)
    )
      ? String(collector.last_reconnect_reason)
      : "unknown";
    const joinResult = JOIN_RESULT_KEYS.has(String(collector.last_join_result))
      ? String(collector.last_join_result)
      : "none";

    return [
      {
        label: i18n("admin.live_metrics.health.operational.health_version"),
        value: collector.version
          ? `v${formatNumber(collector.version)}`
          : i18n("admin.live_metrics.health.not_available"),
        detail: i18n("admin.live_metrics.health.operational.health_version_detail"),
      },
      {
        label: i18n("admin.live_metrics.health.operational.last_join_result"),
        value: i18n(
          `admin.live_metrics.health.join_results.${joinResult}`
        ),
        detail: formatDateTime(collector.last_successful_join_at),
      },
      {
        label: i18n("admin.live_metrics.health.operational.last_reconnect_reason"),
        value: i18n(
          `admin.live_metrics.health.reconnect_reasons.${reconnectReason}`
        ),
        detail: formatDateTime(collector.last_reconnect_at),
      },
      {
        label: i18n("admin.live_metrics.health.operational.oldest_frame"),
        value: formatAge(collector.oldest_frame_age_seconds),
        detail: i18n("admin.live_metrics.health.operational.oldest_frame_detail"),
      },
      {
        label: i18n("admin.live_metrics.health.operational.oldest_event"),
        value: formatAge(collector.oldest_event_age_seconds),
        detail: i18n("admin.live_metrics.health.operational.oldest_event_detail"),
      },
      {
        label: i18n("admin.live_metrics.health.operational.collector_started"),
        value: formatDateTime(collector.collector_started_at),
        detail: i18n("admin.live_metrics.health.operational.collector_started_detail"),
      },
    ];
  }

  get configurationRows() {
    const configuration = this.data?.configuration || {};
    return [
      {
        label: i18n("admin.live_metrics.health.configuration.plugin_enabled"),
        value: enabledLabel(configuration.plugin_enabled),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.async_enabled"),
        value: enabledLabel(configuration.async_current_readings_enabled),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.hyperate_enabled"),
        value: enabledLabel(configuration.hyperate_enabled),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.streaming_enabled"),
        value: enabledLabel(configuration.hyperate_streaming_setting_enabled),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.streaming_operational"),
        value: enabledLabel(configuration.hyperate_streaming_operational),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.client_configured"),
        value: yesNoLabel(configuration.hyperate_client_configured),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.pulsoid_enabled"),
        value: enabledLabel(configuration.pulsoid_enabled),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.max_streams"),
        value: formatNumber(configuration.hyperate_max_streams),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.stall_timeout"),
        value: formatAge(configuration.hyperate_stream_stall_timeout_seconds),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.frontend_poll"),
        value: formatAge(configuration.frontend_poll_interval_seconds),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.provider_refresh"),
        value: formatAge(configuration.provider_refresh_interval_seconds),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.live_threshold"),
        value: formatAge(configuration.live_threshold_seconds),
      },
      {
        label: i18n("admin.live_metrics.health.configuration.stale_threshold"),
        value: formatAge(configuration.stale_threshold_seconds),
      },
    ];
  }

  get privacyRows() {
    const storage = this.data?.storage || {};
    return [
      {
        label: i18n("admin.live_metrics.health.privacy.current_state"),
        value: i18n("admin.live_metrics.health.privacy.latest_only_redis"),
        detail: i18n("admin.live_metrics.health.privacy.current_state_detail", {
          seconds: formatNumber(storage.current_state_ttl_seconds),
        }),
      },
      {
        label: i18n("admin.live_metrics.health.privacy.history"),
        value: storage.historical_reading_storage
          ? i18n("admin.live_metrics.health.yes")
          : i18n("admin.live_metrics.health.no"),
        detail: i18n("admin.live_metrics.health.privacy.history_detail"),
      },
      {
        label: i18n("admin.live_metrics.health.privacy.health_payload"),
        value: i18n("admin.live_metrics.health.privacy.aggregate_only"),
        detail: i18n("admin.live_metrics.health.privacy.health_payload_detail"),
      },
    ];
  }
}
