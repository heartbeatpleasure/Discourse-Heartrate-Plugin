# frozen_string_literal: true

module ::LiveMetrics
  class PageController < ::ApplicationController
    requires_plugin ::LiveMetrics::PLUGIN_NAME

    before_action :ensure_enabled
    before_action :ensure_logged_in, if: -> { SiteSetting.live_metrics_require_login_to_view_page }

    def index
      render layout: "application"
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.live_metrics_enabled
    end
  end
end
