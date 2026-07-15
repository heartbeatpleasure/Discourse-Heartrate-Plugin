import RouteTemplate from "ember-route-template";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .live-metrics-logs {
        --lm-logs-surface: var(--secondary);
        --lm-logs-border: var(--primary-low);
        --lm-logs-muted: var(--primary-medium);
        --lm-logs-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .live-metrics-logs h1,
      .live-metrics-logs h2,
      .live-metrics-logs p {
        margin: 0;
      }

      .lm-logs__hero,
      .lm-logs__panel {
        background: var(--lm-logs-surface);
        border: 1px solid var(--lm-logs-border);
        border-radius: var(--lm-logs-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
        min-width: 0;
      }

      .lm-logs__hero {
        padding: 1.15rem 1.25rem;
      }

      .lm-logs__panel {
        padding: 1rem 1.125rem;
      }

      .lm-logs__header,
      .lm-logs__panel-header,
      .lm-logs__filters {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .lm-logs__header-copy,
      .lm-logs__panel-copy {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        min-width: 0;
      }

      .lm-logs__muted {
        color: var(--lm-logs-muted);
        line-height: 1.4;
      }

      .lm-logs__actions {
        display: flex;
        flex-wrap: wrap;
        justify-content: flex-end;
        gap: 0.5rem;
      }

      .lm-logs__filters {
        align-items: flex-end;
        justify-content: flex-start;
        flex-wrap: wrap;
        margin-top: 1rem;
      }

      .lm-logs__field {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
        min-width: 190px;
      }

      .lm-logs__field span {
        color: var(--primary-high);
        font-weight: 600;
      }

      .lm-logs__field select {
        width: 100%;
      }

      .lm-logs__meta {
        display: flex;
        flex-wrap: wrap;
        gap: 0.75rem 1.25rem;
        margin-top: 0.9rem;
        color: var(--lm-logs-muted);
        font-size: var(--font-down-1);
      }

      .lm-logs__table-wrap {
        margin-top: 1rem;
        overflow-x: auto;
      }

      .lm-logs__table {
        width: 100%;
        min-width: 860px;
        border-collapse: collapse;
      }

      .lm-logs__table th,
      .lm-logs__table td {
        border-bottom: 1px solid var(--lm-logs-border);
        padding: 0.7rem 0.65rem;
        text-align: left;
        vertical-align: top;
      }

      .lm-logs__table th {
        color: var(--primary-high);
        font-size: var(--font-down-1);
        font-weight: 600;
      }

      .lm-logs__table tbody tr:last-child td {
        border-bottom: 0;
      }

      .lm-logs__badge {
        display: inline-flex;
        align-items: center;
        border: 1px solid var(--primary-low);
        border-radius: 999px;
        background: var(--primary-very-low);
        color: var(--primary-high);
        font-size: var(--font-down-1);
        font-weight: 600;
        line-height: 1;
        padding: 0.35rem 0.55rem;
        white-space: nowrap;
      }

      .lm-logs__badge.is-info {
        border-color: var(--tertiary-low);
        background: var(--tertiary-very-low);
        color: var(--tertiary);
      }

      .lm-logs__badge.is-warning {
        border-color: var(--highlight-medium);
        background: var(--highlight-low);
        color: var(--primary-high);
      }

      .lm-logs__badge.is-error {
        border-color: var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      .lm-logs__notice,
      .lm-logs__error,
      .lm-logs__empty {
        border-radius: 12px;
        padding: 0.8rem 0.9rem;
      }

      .lm-logs__notice,
      .lm-logs__empty {
        border: 1px solid var(--primary-low);
        background: var(--secondary);
        color: var(--primary-high);
      }

      .lm-logs__error {
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      @media (max-width: 760px) {
        .lm-logs__header,
        .lm-logs__panel-header {
          flex-direction: column;
        }

        .lm-logs__actions {
          justify-content: flex-start;
        }

        .lm-logs__field {
          width: 100%;
        }
      }
    </style>

    <div class="live-metrics-logs">
      <section class="lm-logs__hero">
        <div class="lm-logs__header">
          <div class="lm-logs__header-copy">
            <h1>{{i18n "admin.live_metrics.logs.title"}}</h1>
            <p class="lm-logs__muted">
              {{i18n "admin.live_metrics.logs.description"}}
            </p>
            <p class="lm-logs__muted">
              {{i18n
                "admin.live_metrics.logs.last_checked"
                time=@controller.generatedAtLabel
              }}
            </p>
          </div>

          <div class="lm-logs__actions">
            <button
              class="btn"
              type="button"
              disabled={{@controller.isLoading}}
              {{on "click" @controller.loadLogs}}
            >
              {{if
                @controller.isLoading
                (i18n "admin.live_metrics.logs.refreshing")
                (i18n "admin.live_metrics.logs.refresh")
              }}
            </button>
            <a class="btn" href="/admin/plugins/live-metrics-health">
              {{i18n "admin.live_metrics.health.short_title"}}
            </a>
            <a class="btn" href="/admin/plugins/live-metrics">
              {{i18n "admin.live_metrics.logs.back_to_overview"}}
            </a>
          </div>
        </div>
      </section>

      {{#if @controller.error}}
        <div class="lm-logs__error">{{@controller.error}}</div>
      {{/if}}

      {{#if @controller.showLoading}}
        <div class="lm-logs__notice">
          {{i18n "admin.live_metrics.logs.loading"}}
        </div>
      {{/if}}

      {{#if @controller.hasData}}
        <section class="lm-logs__panel">
          <div class="lm-logs__panel-header">
            <div class="lm-logs__panel-copy">
              <h2>{{i18n "admin.live_metrics.logs.recent_title"}}</h2>
              <p class="lm-logs__muted">
                {{i18n "admin.live_metrics.logs.recent_description"}}
              </p>
            </div>
          </div>

          <div class="lm-logs__filters">
            <label class="lm-logs__field">
              <span>{{i18n "admin.live_metrics.logs.provider_filter"}}</span>
              <select
                disabled={{@controller.isLoading}}
                {{on "change" @controller.changeProvider}}
              >
                <option
                  value=""
                  selected={{@controller.providerAllSelected}}
                >
                  {{i18n "admin.live_metrics.logs.all_providers"}}
                </option>
                <option
                  value="pulsoid"
                  selected={{@controller.providerPulsoidSelected}}
                >
                  {{i18n "admin.live_metrics.logs.providers.pulsoid"}}
                </option>
                <option
                  value="hyperate"
                  selected={{@controller.providerHyperateSelected}}
                >
                  {{i18n "admin.live_metrics.logs.providers.hyperate"}}
                </option>
                <option
                  value="system"
                  selected={{@controller.providerSystemSelected}}
                >
                  {{i18n "admin.live_metrics.logs.providers.system"}}
                </option>
              </select>
            </label>

            <label class="lm-logs__field">
              <span>{{i18n "admin.live_metrics.logs.severity_filter"}}</span>
              <select
                disabled={{@controller.isLoading}}
                {{on "change" @controller.changeSeverity}}
              >
                <option
                  value=""
                  selected={{@controller.severityAllSelected}}
                >
                  {{i18n "admin.live_metrics.logs.all_severities"}}
                </option>
                <option
                  value="info"
                  selected={{@controller.severityInfoSelected}}
                >
                  {{i18n "admin.live_metrics.logs.severities.info"}}
                </option>
                <option
                  value="warning"
                  selected={{@controller.severityWarningSelected}}
                >
                  {{i18n "admin.live_metrics.logs.severities.warning"}}
                </option>
                <option
                  value="error"
                  selected={{@controller.severityErrorSelected}}
                >
                  {{i18n "admin.live_metrics.logs.severities.error"}}
                </option>
              </select>
            </label>
          </div>

          <div class="lm-logs__meta">
            <span>{{@controller.totalLabel}}</span>
            <span>{{@controller.retentionLabel}}</span>
          </div>

          {{#if @controller.hasEvents}}
            <div class="lm-logs__table-wrap">
              <table class="lm-logs__table">
                <thead>
                  <tr>
                    <th>{{i18n "admin.live_metrics.logs.columns.time"}}</th>
                    <th>{{i18n "admin.live_metrics.logs.columns.severity"}}</th>
                    <th>{{i18n "admin.live_metrics.logs.columns.provider"}}</th>
                    <th>{{i18n "admin.live_metrics.logs.columns.event"}}</th>
                    <th>{{i18n "admin.live_metrics.logs.columns.result"}}</th>
                    <th>{{i18n "admin.live_metrics.logs.columns.client"}}</th>
                  </tr>
                </thead>
                <tbody>
                  {{#each @controller.eventRows as |row|}}
                    <tr>
                      <td>{{row.occurredAt}}</td>
                      <td>
                        <span class="lm-logs__badge {{row.severityClass}}">
                          {{row.severityLabel}}
                        </span>
                      </td>
                      <td>{{row.providerLabel}}</td>
                      <td>{{row.eventLabel}}</td>
                      <td>{{row.resultLabel}}</td>
                      <td>{{row.clientContextLabel}}</td>
                    </tr>
                  {{/each}}
                </tbody>
              </table>
            </div>
          {{else}}
            <div class="lm-logs__empty">
              {{i18n "admin.live_metrics.logs.no_events"}}
            </div>
          {{/if}}
        </section>
      {{/if}}
    </div>
  </template>
);
