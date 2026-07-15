import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

const PROVIDERS = new Set(["pulsoid", "hyperate", "system"]);
const SEVERITIES = new Set(["info", "warning", "error"]);
const EVENTS = new Set([
  "oauth_start",
  "oauth_callback",
  "provider_connect",
  "provider_disconnect",
  "provider_refresh",
  "stream_join",
  "stream_reconnect",
  "stream_capacity",
  "unknown",
]);
const RESULTS = new Set([
  "redirected",
  "success",
  "disconnected",
  "recovered",
  "sharing_denied",
  "not_configured",
  "state_mismatch",
  "provider_error",
  "missing_authorization_code",
  "database_not_ready",
  "connect_failed",
  "disconnect_failed",
  "invalid_device_id",
  "disabled",
  "authorization_failed",
  "transport_stalled",
  "no_data",
  "transport_error",
  "unexpected_error",
  "stream_ended",
  "start_failed",
  "limit_reached",
  "unknown",
]);
const CLIENT_CONTEXTS = new Set([
  "desktop_browser",
  "mobile_browser",
  "embedded_webview",
  "server",
  "unknown",
]);

function formatDateTime(value) {
  if (!value) {
    return i18n("admin.live_metrics.logs.not_available");
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return i18n("admin.live_metrics.logs.not_available");
  }

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "medium",
  }).format(date);
}

function extractError(error) {
  return (
    error?.jqXHR?.responseJSON?.errors?.[0] ||
    error?.responseJSON?.errors?.[0] ||
    error?.message ||
    i18n("admin.live_metrics.logs.load_error")
  );
}

function normalizedKey(value, allowed, fallback = "unknown") {
  const normalized = String(value || "");
  return allowed.has(normalized) ? normalized : fallback;
}

export default class AdminPluginsLiveMetricsLogsController extends Controller {
  @tracked data = null;
  @tracked isLoading = false;
  @tracked error = null;
  @tracked providerFilter = "";
  @tracked severityFilter = "";

  resetState() {
    this.data = null;
    this.isLoading = false;
    this.error = null;
    this.providerFilter = "";
    this.severityFilter = "";
  }

  @action
  async loadLogs() {
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.error = null;

    const query = new URLSearchParams();
    if (this.providerFilter) {
      query.set("provider", this.providerFilter);
    }
    if (this.severityFilter) {
      query.set("severity", this.severityFilter);
    }
    query.set("limit", "200");

    try {
      this.data = await ajax(
        `/admin/plugins/live-metrics/logs.json?${query.toString()}`
      );
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.isLoading = false;
    }
  }

  @action
  changeProvider(event) {
    this.providerFilter = event.target.value;
    this.loadLogs();
  }

  @action
  changeSeverity(event) {
    this.severityFilter = event.target.value;
    this.loadLogs();
  }

  get providerAllSelected() {
    return this.providerFilter === "";
  }

  get providerPulsoidSelected() {
    return this.providerFilter === "pulsoid";
  }

  get providerHyperateSelected() {
    return this.providerFilter === "hyperate";
  }

  get providerSystemSelected() {
    return this.providerFilter === "system";
  }

  get severityAllSelected() {
    return this.severityFilter === "";
  }

  get severityInfoSelected() {
    return this.severityFilter === "info";
  }

  get severityWarningSelected() {
    return this.severityFilter === "warning";
  }

  get severityErrorSelected() {
    return this.severityFilter === "error";
  }

  get hasData() {
    return Boolean(this.data);
  }

  get showLoading() {
    return !this.hasData && this.isLoading;
  }

  get generatedAtLabel() {
    return formatDateTime(this.data?.generated_at);
  }

  get retentionLabel() {
    return i18n("admin.live_metrics.logs.retention", {
      days: Number(this.data?.retention_days || 7),
      max: Number(this.data?.max_events || 500),
    });
  }

  get totalLabel() {
    return i18n("admin.live_metrics.logs.total", {
      count: Number(this.data?.total_events || 0),
    });
  }

  get eventRows() {
    return (this.data?.events || []).map((entry) => {
      const severity = normalizedKey(entry?.severity, SEVERITIES, "info");
      const provider = normalizedKey(entry?.provider, PROVIDERS, "system");
      const event = normalizedKey(entry?.event, EVENTS);
      const result = normalizedKey(entry?.result, RESULTS);
      const clientContext = normalizedKey(
        entry?.client_context,
        CLIENT_CONTEXTS
      );

      return {
        id: String(entry?.id || `${entry?.occurred_at_ms}-${event}-${result}`),
        occurredAt: formatDateTime(entry?.occurred_at),
        severity,
        severityLabel: i18n(
          `admin.live_metrics.logs.severities.${severity}`
        ),
        severityClass: `is-${severity}`,
        providerLabel: i18n(`admin.live_metrics.logs.providers.${provider}`),
        eventLabel: i18n(`admin.live_metrics.logs.events.${event}`),
        resultLabel: i18n(`admin.live_metrics.logs.results.${result}`),
        clientContextLabel: i18n(
          `admin.live_metrics.logs.client_contexts.${clientContext}`
        ),
      };
    });
  }

  get hasEvents() {
    return this.eventRows.length > 0;
  }
}
