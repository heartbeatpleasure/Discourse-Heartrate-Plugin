import RouteTemplate from "ember-route-template";
import { i18n } from "discourse-i18n";

export default RouteTemplate(
  <template>
    <style>
      .live-metrics-admin-landing {
        --lm-surface: var(--secondary);
        --lm-surface-alt: var(--primary-very-low);
        --lm-border: var(--primary-low);
        --lm-muted: var(--primary-medium);
        --lm-radius: 18px;
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .live-metrics-admin-landing h1,
      .live-metrics-admin-landing h2,
      .live-metrics-admin-landing h3,
      .live-metrics-admin-landing p {
        margin: 0;
      }

      .lm-landing__hero,
      .lm-landing__card {
        background: var(--lm-surface);
        border: 1px solid var(--lm-border);
        border-radius: var(--lm-radius);
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
      }

      .lm-landing__hero {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
        padding: 1.25rem 1.35rem;
      }

      .lm-landing__hero-copy {
        display: flex;
        flex-direction: column;
        gap: 0.45rem;
        max-width: 760px;
      }

      .lm-landing__hero-copy p,
      .lm-landing__card-description,
      .lm-landing__section-description {
        color: var(--lm-muted);
      }

      .lm-landing__section-header {
        display: flex;
        align-items: flex-end;
        justify-content: space-between;
        gap: 1rem;
        padding: 0 0.25rem;
      }

      .lm-landing__section-copy {
        display: flex;
        flex-direction: column;
        gap: 0.2rem;
      }

      .lm-landing__grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
        gap: 1rem;
      }

      .lm-landing__card {
        display: flex;
        flex-direction: column;
        gap: 0.85rem;
        min-height: 170px;
        padding: 1rem 1.1rem;
        text-decoration: none;
        color: var(--primary);
        transition:
          border-color 0.12s ease,
          box-shadow 0.12s ease,
          transform 0.12s ease;
      }

      .lm-landing__card:hover,
      .lm-landing__card:focus {
        border-color: var(--tertiary-medium);
        box-shadow: 0 6px 18px rgba(0, 0, 0, 0.06);
        color: var(--primary);
        text-decoration: none;
        transform: translateY(-1px);
      }

      .lm-landing__card.is-primary {
        border-color: var(--tertiary-low);
        background: linear-gradient(
          180deg,
          var(--secondary) 0%,
          var(--tertiary-very-low) 100%
        );
      }

      .lm-landing__card-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 0.8rem;
      }

      .lm-landing__card-title {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
        min-width: 0;
      }

      .lm-landing__card-title h3 {
        font-size: var(--font-up-1);
        line-height: 1.15;
      }

      .lm-landing__card-description {
        line-height: 1.35;
      }

      .lm-landing__card-badge {
        display: inline-flex;
        width: max-content;
        max-width: 100%;
        border: 1px solid var(--primary-low);
        border-radius: 999px;
        background: var(--primary-very-low);
        color: var(--primary-medium);
        font-size: var(--font-down-1);
        line-height: 1;
        padding: 0.35rem 0.55rem;
        white-space: nowrap;
      }

      .lm-landing__card-badge.is-primary {
        border-color: var(--tertiary-low);
        background: var(--tertiary-low);
        color: var(--tertiary);
      }

      .lm-landing__card-action {
        margin-top: auto;
        display: inline-flex;
        align-items: center;
        gap: 0.35rem;
        color: var(--tertiary);
        font-weight: 600;
      }

      @media (max-width: 700px) {
        .lm-landing__hero {
          flex-direction: column;
        }

        .lm-landing__grid {
          grid-template-columns: 1fr;
        }
      }
    </style>

    <div class="live-metrics-admin-landing">
      <section class="lm-landing__hero">
        <div class="lm-landing__hero-copy">
          <h1>{{i18n "admin.live_metrics.title"}}</h1>
          <p>{{i18n "admin.live_metrics.description"}}</p>
        </div>

        <a
          class="btn btn-primary"
          href="/admin/site_settings/category/all_results?filter=live_metrics"
        >
          {{i18n "admin.live_metrics.open_settings"}}
        </a>
      </section>

      <div class="lm-landing__section-header">
        <div class="lm-landing__section-copy">
          <h2>{{i18n "admin.live_metrics.overview_title"}}</h2>
          <p class="lm-landing__section-description">
            {{i18n "admin.live_metrics.overview_description"}}
          </p>
        </div>
      </div>

      <section
        class="lm-landing__grid"
        aria-label={{i18n "admin.live_metrics.overview_title"}}
      >
        <a
          class="lm-landing__card is-primary"
          href="/admin/site_settings/category/all_results?filter=live_metrics"
        >
          <div class="lm-landing__card-header">
            <div class="lm-landing__card-title">
              <span class="lm-landing__card-badge is-primary">
                {{i18n "admin.live_metrics.category_configuration"}}
              </span>
              <h3>{{i18n "admin.live_metrics.open_settings"}}</h3>
            </div>
          </div>
          <p class="lm-landing__card-description">
            {{i18n "admin.live_metrics.settings_description"}}
          </p>
          <span class="lm-landing__card-action">
            {{i18n "admin.live_metrics.open_settings"}}
          </span>
        </a>

        <a class="lm-landing__card" href="/admin/plugins/live-metrics-health">
          <div class="lm-landing__card-header">
            <div class="lm-landing__card-title">
              <span class="lm-landing__card-badge">
                {{i18n "admin.live_metrics.category_monitoring"}}
              </span>
              <h3>{{i18n "admin.live_metrics.health.short_title"}}</h3>
            </div>
          </div>
          <p class="lm-landing__card-description">
            {{i18n "admin.live_metrics.health.description"}}
          </p>
          <span class="lm-landing__card-action">
            {{i18n "admin.live_metrics.open_tool"}}
          </span>
        </a>

        <a class="lm-landing__card" href="/admin/plugins/live-metrics-logs">
          <div class="lm-landing__card-header">
            <div class="lm-landing__card-title">
              <span class="lm-landing__card-badge">
                {{i18n "admin.live_metrics.category_monitoring"}}
              </span>
              <h3>{{i18n "admin.live_metrics.logs.short_title"}}</h3>
            </div>
          </div>
          <p class="lm-landing__card-description">
            {{i18n "admin.live_metrics.logs.description"}}
          </p>
          <span class="lm-landing__card-action">
            {{i18n "admin.live_metrics.open_tool"}}
          </span>
        </a>
      </section>
    </div>
  </template>
);
