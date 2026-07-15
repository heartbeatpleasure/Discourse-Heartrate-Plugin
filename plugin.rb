# frozen_string_literal: true

# name: Discourse-Heartrate-Plugin
# about: Heartrate sharing
# version: 0.1.0
# authors: Chris
# url: https://github.com

add_admin_route "admin.live_metrics.title", "liveMetrics"

enabled_site_setting :live_metrics_enabled

module ::LiveMetrics
  PLUGIN_NAME = "Discourse-Heartrate-Plugin"

  def self.enabled_provider_names
    providers = []
    providers << ::LiveMetrics::ProviderAccount::PROVIDER_PULSOID if SiteSetting.live_metrics_pulsoid_enabled
    providers << ::LiveMetrics::ProviderAccount::PROVIDER_HYPERATE if SiteSetting.live_metrics_hyperate_enabled
    providers
  rescue
    []
  end
end

after_initialize do
  begin
    Rails.application.config.filter_parameters |= [
      :access_token,
      :refresh_token,
      :token,
      :client_secret,
      :code,
      :authorization,
      :cookie,
      :state,
      :api_key,
      :device_id,
    ]
  rescue
    # Keep plugin boot resilient if Rails filter configuration is unavailable.
  end

  require_relative "lib/live_metrics/token_cipher"
  require_relative "lib/live_metrics/permissions"
  require_relative "lib/live_metrics/pulsoid_client"
  require_relative "lib/live_metrics/hyperate_client"

  require_dependency File.expand_path("app/models/live_metrics/provider_account.rb", __dir__)
  require_relative "lib/live_metrics/current_state_store"
  require_relative "lib/live_metrics/admin_event_log"
  require_relative "lib/live_metrics/hyperate_streaming_registry"
  require_relative "lib/live_metrics/refresh_coordinator"
  require_relative "lib/live_metrics/hyperate_streaming_session"
  require_relative "lib/live_metrics/hyperate_streaming_supervisor"
  require_relative "lib/live_metrics/hyperate_streaming_demon"
  require_relative "lib/live_metrics/admin_health"
  require_dependency File.expand_path(
    "app/jobs/regular/live_metrics/refresh_provider_account.rb",
    __dir__,
  )
  require_dependency File.expand_path(
    "app/jobs/scheduled/live_metrics/recover_refresh_loops.rb",
    __dir__,
  )
  require_dependency File.expand_path("app/controllers/live_metrics/page_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/live_metrics/auth_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/live_metrics/api_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/live_metrics/admin_health_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/live_metrics/admin_logs_controller.rb", __dir__)

  on(:site_setting_changed) do |name, _old_value, _new_value|
    next unless %i[
      live_metrics_enabled
      live_metrics_async_current_readings_enabled
      live_metrics_pulsoid_enabled
      live_metrics_hyperate_enabled
      live_metrics_hyperate_streaming_enabled
      live_metrics_hyperate_max_streams
      live_metrics_hyperate_stream_stall_timeout_seconds
      live_metrics_hyperate_api_key
      live_metrics_hyperate_ws_url
    ].include?(name)

    ::LiveMetrics::RefreshCoordinator.sync_all
  end

  register_demon_process(::LiveMetrics::HypeRateStreamingDemon)

  Discourse::Application.routes.append do
    get "/admin/plugins/live-metrics" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/live-metrics-health" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/live-metrics-logs" => "admin/plugins#index", constraints: AdminConstraint.new
    get "/admin/plugins/live-metrics/health" => "live_metrics/admin_health#index",
        defaults: { format: :json },
        constraints: AdminConstraint.new
    get "/admin/plugins/live-metrics/logs" => "live_metrics/admin_logs#index",
        defaults: { format: :json },
        constraints: AdminConstraint.new

    get "/live-metrics" => "live_metrics/page#index"

    # Keep an API-prefixed connect alias because /live-metrics/api/* is known to
    # route correctly on Discourse installs where deeper frontend page paths may
    # be claimed by the Ember fallback before OAuth can start. The legacy auth
    # path stays available for backwards compatibility and as the registered
    # OAuth callback path.
    get "/live-metrics/api/connect/pulsoid" => "live_metrics/auth#pulsoid_start"
    get "/live-metrics/auth/pulsoid/start" => "live_metrics/auth#pulsoid_start"
    get "/live-metrics/auth/pulsoid/callback" => "live_metrics/auth#pulsoid_callback"
    delete "/live-metrics/auth/pulsoid" => "live_metrics/auth#pulsoid_disconnect", defaults: { format: :json }

    put "/live-metrics/api/connect/hyperate" => "live_metrics/api#connect_hyperate", defaults: { format: :json }
    patch "/live-metrics/api/connect/hyperate" => "live_metrics/api#connect_hyperate", defaults: { format: :json }
    delete "/live-metrics/api/connect/hyperate" => "live_metrics/api#disconnect_hyperate", defaults: { format: :json }

    get "/live-metrics/api/config" => "live_metrics/api#plugin_config", defaults: { format: :json }
    get "/live-metrics/api/me" => "live_metrics/api#me", defaults: { format: :json }
    get "/live-metrics/api/user-search" => "live_metrics/api#user_search", defaults: { format: :json }
    put "/live-metrics/api/accounts/:provider/audience-users" => "live_metrics/api#add_audience_user", defaults: { format: :json }
    delete "/live-metrics/api/accounts/:provider/audience-users" => "live_metrics/api#remove_audience_user", defaults: { format: :json }
    put "/live-metrics/api/me/settings" => "live_metrics/api#update_me", defaults: { format: :json }
    patch "/live-metrics/api/me/settings" => "live_metrics/api#update_me", defaults: { format: :json }
    put "/live-metrics/api/accounts/:provider/settings" => "live_metrics/api#update_account", defaults: { format: :json }
    patch "/live-metrics/api/accounts/:provider/settings" => "live_metrics/api#update_account", defaults: { format: :json }
    put "/live-metrics/api/accounts/:provider/activate" => "live_metrics/api#activate_account", defaults: { format: :json }
    patch "/live-metrics/api/accounts/:provider/activate" => "live_metrics/api#activate_account", defaults: { format: :json }
    get "/live-metrics/api/live-preview" => "live_metrics/api#live_preview", defaults: { format: :json }
    get "/live-metrics/api/directory" => "live_metrics/api#directory", defaults: { format: :json }
    get "/live-metrics/api/user-cards" => "live_metrics/api#user_cards", defaults: { format: :json }
    get "/live-metrics/api/users/:username" => "live_metrics/api#user", defaults: { format: :json }
  end
end
