# frozen_string_literal: true

# name: Discourse-Heartrate-Plugin
# about: Heartrate sharing
# version: 0.1.0
# authors: Chris
# url: https://github.com

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
  require_dependency File.expand_path("app/controllers/live_metrics/page_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/live_metrics/auth_controller.rb", __dir__)
  require_dependency File.expand_path("app/controllers/live_metrics/api_controller.rb", __dir__)

  Discourse::Application.routes.append do
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
    put "/live-metrics/api/me/settings" => "live_metrics/api#update_me", defaults: { format: :json }
    patch "/live-metrics/api/me/settings" => "live_metrics/api#update_me", defaults: { format: :json }
    put "/live-metrics/api/accounts/:provider/settings" => "live_metrics/api#update_account", defaults: { format: :json }
    patch "/live-metrics/api/accounts/:provider/settings" => "live_metrics/api#update_account", defaults: { format: :json }
    put "/live-metrics/api/accounts/:provider/activate" => "live_metrics/api#activate_account", defaults: { format: :json }
    patch "/live-metrics/api/accounts/:provider/activate" => "live_metrics/api#activate_account", defaults: { format: :json }
    get "/live-metrics/api/live-preview" => "live_metrics/api#live_preview", defaults: { format: :json }
    get "/live-metrics/api/directory" => "live_metrics/api#directory", defaults: { format: :json }
    get "/live-metrics/api/users/:username" => "live_metrics/api#user", defaults: { format: :json }
  end
end
