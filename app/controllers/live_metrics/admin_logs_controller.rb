# frozen_string_literal: true

module ::LiveMetrics
  class AdminLogsController < ::Admin::AdminController
    requires_plugin "Discourse-Heartrate-Plugin"

    def index
      response.headers["Cache-Control"] = "no-store"
      render_json_dump(
        events: ::LiveMetrics::AdminEventLog.recent(
          provider: params[:provider],
          severity: params[:severity],
          limit: params[:limit],
        ),
        generated_at: Time.zone.now.iso8601,
        total_events: ::LiveMetrics::AdminEventLog.total_count,
        retention_days: (::LiveMetrics::AdminEventLog::RETENTION_SECONDS / 1.day).to_i,
        max_events: ::LiveMetrics::AdminEventLog::MAX_EVENTS,
      )
    end
  end
end
