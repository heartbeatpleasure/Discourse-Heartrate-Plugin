import RouteTemplate from "ember-route-template";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .live-metrics-health {
        --lm-health-surface: var(--secondary);
        --lm-health-surface-alt: var(--primary-very-low);
        --lm-health-border: var(--primary-low);
        --lm-health-muted: var(--primary-medium);
        --lm-health-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .live-metrics-health h1,
      .live-metrics-health h2,
      .live-metrics-health h3,
      .live-metrics-health p,
      .live-metrics-health ul {
        margin: 0;
      }

      .lm-health__hero,
      .lm-health__panel {
        background: var(--lm-health-surface);
        border: 1px solid var(--lm-health-border);
        border-radius: var(--lm-health-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
        min-width: 0;
      }

      .lm-health__hero {
        padding: 1.15rem 1.25rem;
      }

      .lm-health__panel {
        padding: 1rem 1.125rem;
      }

      .lm-health__header,
      .lm-health__panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .lm-health__header-copy,
      .lm-health__panel-copy {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
        min-width: 0;
      }

      .lm-health__muted,
      .lm-health__card-detail,
      .lm-health__row-detail,
      .lm-health__warning-description {
        color: var(--lm-health-muted);
        font-size: var(--font-down-1);
      }

      .lm-health__actions {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: flex-end;
        gap: 0.65rem;
      }

      .lm-health__status {
        display: inline-flex;
        align-items: center;
        gap: 0.45rem;
        min-height: 2.2rem;
        border: 1px solid var(--lm-health-border);
        border-radius: 999px;
        background: var(--lm-health-surface-alt);
        padding: 0.35rem 0.7rem;
        font-weight: 700;
      }

      .lm-health__status-dot {
        width: 0.72rem;
        height: 0.72rem;
        border-radius: 999px;
        background: var(--primary-medium);
        flex: 0 0 auto;
      }

      .lm-health__status-dot.is-ok,
      .lm-health__badge.is-ok {
        background: var(--success-low);
        border-color: var(--success-low-mid);
        color: var(--success);
      }

      .lm-health__status-dot.is-ok {
        background: var(--success);
      }

      .lm-health__status-dot.is-warning,
      .lm-health__badge.is-warning {
        background: var(--highlight-low);
        border-color: var(--highlight-medium);
        color: var(--primary-high);
      }

      .lm-health__status-dot.is-warning {
        background: var(--highlight);
      }

      .lm-health__status-dot.is-critical,
      .lm-health__badge.is-critical {
        background: var(--danger-low);
        border-color: var(--danger-low-mid);
        color: var(--danger);
      }

      .lm-health__status-dot.is-critical {
        background: var(--danger);
      }

      .lm-health__status-dot.is-info,
      .lm-health__badge.is-info {
        background: var(--primary-very-low);
        border-color: var(--primary-low);
        color: var(--primary-high);
      }

      .lm-health__status-dot.is-info {
        background: var(--primary-medium);
      }

      .lm-health__summary-grid,
      .lm-health__activity-grid,
      .lm-health__rows {
        display: grid;
        gap: 1rem;
      }

      .lm-health__summary-grid {
        grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
      }

      .lm-health__activity-grid {
        grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
        margin-top: 1rem;
      }

      .lm-health__summary-card,
      .lm-health__activity-card,
      .lm-health__row {
        background: var(--lm-health-surface-alt);
        border: 1px solid var(--lm-health-border);
        border-radius: 16px;
        min-width: 0;
      }

      .lm-health__summary-card {
        position: relative;
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        padding: 0.9rem 1rem;
      }

      .lm-health__summary-card .lm-health__badge {
        position: absolute;
        right: 0.8rem;
        top: 0.8rem;
      }

      .lm-health__card-label,
      .lm-health__activity-label,
      .lm-health__row-label {
        color: var(--lm-health-muted);
        font-size: var(--font-down-1);
        font-weight: 700;
      }

      .lm-health__card-value {
        padding-right: 1.75rem;
        font-size: var(--font-up-1);
        font-weight: 700;
        line-height: 1.2;
        overflow-wrap: anywhere;
      }

      .lm-health__activity-card {
        padding: 0.8rem 0.9rem;
      }

      .lm-health__activity-value {
        margin-top: 0.25rem;
        font-size: var(--font-up-2);
        font-weight: 700;
      }

      .lm-health__badge {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-width: 1.25rem;
        min-height: 1.25rem;
        border: 1px solid var(--lm-health-border);
        border-radius: 999px;
        padding: 0.15rem 0.4rem;
        font-size: var(--font-down-2);
        font-weight: 800;
        line-height: 1;
      }

      .lm-health__warnings {
        display: grid;
        gap: 0.75rem;
        margin-top: 1rem;
      }

      .lm-health__warning {
        display: grid;
        grid-template-columns: auto minmax(0, 1fr);
        gap: 0.75rem;
        align-items: flex-start;
        border: 1px solid var(--lm-health-border);
        border-radius: 14px;
        background: var(--lm-health-surface-alt);
        padding: 0.8rem 0.9rem;
      }

      .lm-health__warning-copy {
        display: flex;
        flex-direction: column;
        gap: 0.2rem;
        min-width: 0;
      }

      .lm-health__warning-title {
        font-weight: 700;
      }

      .lm-health__rows {
        grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
        margin-top: 1rem;
      }

      .lm-health__row {
        padding: 0.8rem 0.9rem;
      }

      .lm-health__row-value {
        margin-top: 0.2rem;
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .lm-health__row-detail {
        margin-top: 0.3rem;
        line-height: 1.35;
      }

      .lm-health__notice,
      .lm-health__error {
        border-radius: 12px;
        padding: 0.75rem 0.85rem;
      }

      .lm-health__notice {
        border: 1px solid var(--primary-low);
        background: var(--secondary);
        color: var(--primary-high);
      }

      .lm-health__error {
        border: 1px solid var(--danger-low-mid);
        background: var(--danger-low);
        color: var(--danger);
      }

      .lm-health__privacy-note {
        margin-top: 1rem;
        border: 1px solid var(--success-low-mid);
        border-radius: 14px;
        background: var(--success-low);
        color: var(--success);
        padding: 0.8rem 0.9rem;
        line-height: 1.4;
      }

      @media (max-width: 760px) {
        .lm-health__header,
        .lm-health__panel-header {
          flex-direction: column;
        }

        .lm-health__actions {
          justify-content: flex-start;
        }

        .lm-health__summary-grid,
        .lm-health__activity-grid,
        .lm-health__rows {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="live-metrics-health">
      <section class="lm-health__hero">
        <div class="lm-health__header">
          <div class="lm-health__header-copy">
            <h1>{{i18n "admin.live_metrics.health.title"}}</h1>
            <p class="lm-health__muted">
              {{i18n "admin.live_metrics.health.description"}}
            </p>
            <p class="lm-health__muted">
              {{i18n
                "admin.live_metrics.health.last_checked"
                time=@controller.generatedAtLabel
              }}
            </p>
          </div>

          <div class="lm-health__actions">
            <span class="lm-health__status">
              <span
                class="lm-health__status-dot {{@controller.overallBadgeClass}}"
              ></span>
              <span>{{@controller.overallLabel}}</span>
            </span>
            <button
              class="btn"
              type="button"
              disabled={{@controller.isLoading}}
              {{on "click" @controller.loadHealth}}
            >
              {{if
                @controller.isLoading
                (i18n "admin.live_metrics.health.refreshing")
                (i18n "admin.live_metrics.health.refresh")
              }}
            </button>
            <a
              class="btn"
              href="/admin/site_settings/category/all_results?filter=live_metrics"
            >
              {{i18n "admin.live_metrics.open_settings"}}
            </a>
            <a class="btn" href="/admin/plugins/live-metrics">
              {{i18n "admin.live_metrics.health.back_to_overview"}}
            </a>
          </div>
        </div>
      </section>

      {{#if @controller.error}}
        <div class="lm-health__error">{{@controller.error}}</div>
      {{/if}}

      {{#unless @controller.hasData}}
        <div class="lm-health__notice">
          {{i18n "admin.live_metrics.health.loading"}}
        </div>
      {{/unless}}

      {{#if @controller.hasData}}
        <section class="lm-health__summary-grid">
          {{#each @controller.summaryCards as |card|}}
            <article class="lm-health__summary-card">
              <span class="lm-health__badge {{card.badgeClass}}">●</span>
              <div class="lm-health__card-label">{{card.label}}</div>
              <div class="lm-health__card-value">{{card.value}}</div>
              <div class="lm-health__card-detail">{{card.detail}}</div>
            </article>
          {{/each}}
        </section>

        <section class="lm-health__panel">
          <div class="lm-health__panel-header">
            <div class="lm-health__panel-copy">
              <h2>{{i18n "admin.live_metrics.health.status_title"}}</h2>
              <p class="lm-health__muted">
                {{@controller.overallDescription}}
              </p>
            </div>
          </div>

          {{#if @controller.hasWarnings}}
            <div class="lm-health__warnings">
              {{#each @controller.warningItems as |warning|}}
                <article class="lm-health__warning">
                  <span class="lm-health__badge {{warning.badgeClass}}">!</span>
                  <div class="lm-health__warning-copy">
                    <div class="lm-health__warning-title">{{warning.title}}</div>
                    <div class="lm-health__warning-description">
                      {{warning.description}}
                    </div>
                  </div>
                </article>
              {{/each}}
            </div>
          {{else}}
            <div class="lm-health__privacy-note">
              {{i18n "admin.live_metrics.health.no_warnings"}}
            </div>
          {{/if}}
        </section>

        <section class="lm-health__panel">
          <div class="lm-health__panel-header">
            <div class="lm-health__panel-copy">
              <h2>{{i18n "admin.live_metrics.health.activity_title"}}</h2>
              <p class="lm-health__muted">
                {{i18n "admin.live_metrics.health.activity_description"}}
              </p>
            </div>
          </div>

          <div class="lm-health__activity-grid">
            {{#each @controller.activityCards as |card|}}
              <article class="lm-health__activity-card">
                <div class="lm-health__activity-label">{{card.label}}</div>
                <div class="lm-health__activity-value">{{card.value}}</div>
              </article>
            {{/each}}
          </div>
        </section>

        <section class="lm-health__panel">
          <div class="lm-health__panel-header">
            <div class="lm-health__panel-copy">
              <h2>{{i18n "admin.live_metrics.health.operational_title"}}</h2>
              <p class="lm-health__muted">
                {{i18n "admin.live_metrics.health.operational_description"}}
              </p>
            </div>
          </div>

          <div class="lm-health__rows">
            {{#each @controller.operationalRows as |row|}}
              <article class="lm-health__row">
                <div class="lm-health__row-label">{{row.label}}</div>
                <div class="lm-health__row-value">{{row.value}}</div>
                <div class="lm-health__row-detail">{{row.detail}}</div>
              </article>
            {{/each}}
          </div>
        </section>

        <section class="lm-health__panel">
          <div class="lm-health__panel-header">
            <div class="lm-health__panel-copy">
              <h2>{{i18n "admin.live_metrics.health.configuration_title"}}</h2>
              <p class="lm-health__muted">
                {{i18n "admin.live_metrics.health.configuration_description"}}
              </p>
            </div>
          </div>

          <div class="lm-health__rows">
            {{#each @controller.configurationRows as |row|}}
              <article class="lm-health__row">
                <div class="lm-health__row-label">{{row.label}}</div>
                <div class="lm-health__row-value">{{row.value}}</div>
              </article>
            {{/each}}
          </div>
        </section>

        <section class="lm-health__panel">
          <div class="lm-health__panel-header">
            <div class="lm-health__panel-copy">
              <h2>{{i18n "admin.live_metrics.health.privacy_title"}}</h2>
              <p class="lm-health__muted">
                {{i18n "admin.live_metrics.health.privacy_description"}}
              </p>
            </div>
          </div>

          <div class="lm-health__rows">
            {{#each @controller.privacyRows as |row|}}
              <article class="lm-health__row">
                <div class="lm-health__row-label">{{row.label}}</div>
                <div class="lm-health__row-value">{{row.value}}</div>
                <div class="lm-health__row-detail">{{row.detail}}</div>
              </article>
            {{/each}}
          </div>

          <div class="lm-health__privacy-note">
            {{i18n "admin.live_metrics.health.privacy_note"}}
          </div>
        </section>
      {{/if}}
    </div>
  </template>
);
