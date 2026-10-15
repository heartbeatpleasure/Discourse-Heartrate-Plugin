# frozen_string_literal: true

module ::LiveMetrics
  class AdminActivitiesController < ::Admin::AdminController
    requires_plugin "Discourse-Heartrate-Plugin"

    # Staff can clear an inappropriate activity without touching provider
    # credentials, the member's privacy choices, or their live readings.
    def destroy
      username = params[:username].to_s.strip.downcase
      raise Discourse::NotFound if username.blank? || username.length > 60

      user = ::User.find_by(username_lower: username)
      raise Discourse::NotFound if user.blank?

      count =
        if ::LiveMetrics::Activity.table_exists?
          ::LiveMetrics::Activity.where(user_id: user.id).delete_all
        else
          0
        end
      response.headers["Cache-Control"] = "no-store"
      render_json_dump(cleared: count.positive?)
    end
  end
end
