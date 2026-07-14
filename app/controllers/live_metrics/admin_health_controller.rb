# frozen_string_literal: true

module ::LiveMetrics
  class AdminHealthController < ::Admin::AdminController
    requires_plugin "Discourse-Heartrate-Plugin"

    def index
      response.headers["Cache-Control"] = "no-store"
      render_json_dump(::LiveMetrics::AdminHealth.summary)
    end
  end
end
