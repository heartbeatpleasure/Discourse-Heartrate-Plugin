# frozen_string_literal: true

RSpec.describe "LiveMetrics Pulsoid OAuth", type: :request do
  fab!(:user)

  before do
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_pulsoid_enabled = true
    SiteSetting.live_metrics_pulsoid_client_id = "client-id"
    SiteSetting.live_metrics_pulsoid_client_secret = "client-secret"
    SiteSetting.live_metrics_allowed_sharer_groups = "trust_level_0"
    LiveMetrics::AdminEventLog.clear
    sign_in(user)
  end

  after { LiveMetrics::AdminEventLog.clear }

  it "records a broad client context when OAuth leaves Discourse" do
    LiveMetrics::PulsoidClient.stubs(:authorization_url).returns(
      "https://pulsoid.example/oauth/authorize",
    )

    get "/live-metrics/api/connect/pulsoid",
        headers: {
          "HTTP_USER_AGENT" =>
            "Mozilla/5.0 (Linux; Android 14; wv) AppleWebKit/537.36",
        }

    expect(response.status).to eq(302)
    expect(response.location).to eq("https://pulsoid.example/oauth/authorize")
    expect(LiveMetrics::AdminEventLog.recent.first).to include(
      provider: "pulsoid",
      event: "oauth_start",
      result: "redirected",
      client_context: "embedded_webview",
    )
  end

  it "applies the preferred sharing defaults to a new Pulsoid connection" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    SiteSetting.live_metrics_allowed_visibility_options = "private|logged_in"
    LiveMetrics::PulsoidClient.stubs(:exchange_code!).returns(
      "access_token" => "access-token",
      "refresh_token" => "refresh-token",
      "expires_in" => 3600,
    )
    LiveMetrics::PulsoidClient.stubs(:profile).returns(nil)

    get "/live-metrics/api/connect/pulsoid"
    expect(response.status).to eq(302)
    state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")

    get "/live-metrics/auth/pulsoid/callback",
        params: { state: state, code: "authorization-code" }

    expect(response.status).to eq(302)
    expect(response.location).to include("connected=pulsoid")
    connected = LiveMetrics::ProviderAccount.find_by!(
      user: user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
    )
    expect(connected).to have_attributes(
      active: true,
      visibility: "logged_in",
      show_on_user_card: true,
      show_in_directory: true,
      show_on_profile: false,
    )
  end

  it "preserves sharing preferences when an existing Pulsoid connection is reauthorized" do
    SiteSetting.live_metrics_async_current_readings_enabled = false
    existing = LiveMetrics::ProviderAccount.new(
      user: user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
      visibility: "private",
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
      active: true,
    )
    existing.access_token = "old-access-token"
    existing.refresh_token = "old-refresh-token"
    existing.save!

    LiveMetrics::PulsoidClient.stubs(:exchange_code!).returns(
      "access_token" => "new-access-token",
      "refresh_token" => "new-refresh-token",
      "expires_in" => 3600,
    )
    LiveMetrics::PulsoidClient.stubs(:profile).returns(nil)

    get "/live-metrics/api/connect/pulsoid"
    state = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("state")
    get "/live-metrics/auth/pulsoid/callback",
        params: { state: state, code: "authorization-code" }

    expect(response.status).to eq(302)
    expect(existing.reload).to have_attributes(
      visibility: "private",
      show_on_user_card: false,
      show_in_directory: false,
      show_on_profile: false,
    )
  end

  it "records an OAuth state mismatch without weakening state validation" do
    get "/live-metrics/auth/pulsoid/callback",
        params: { state: "unexpected", code: "authorization-code" }

    expect(response.status).to eq(302)
    expect(response.location).to include("error=oauth_state_mismatch")
    expect(LiveMetrics::AdminEventLog.recent.first).to include(
      provider: "pulsoid",
      event: "oauth_callback",
      result: "state_mismatch",
      severity: "warning",
    )
  end
end
