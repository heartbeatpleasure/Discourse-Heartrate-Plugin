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

  it "invalidates Pulsoid stream ownership and current state on disconnect" do
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_pulsoid_streaming_enabled = true
    SiteSetting.live_metrics_pulsoid_ws_url =
      "wss://dev.pulsoid.net/api/v1/data/real_time"

    account = LiveMetrics::ProviderAccount.new(
      user: user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
    account.access_token = "disconnect-access"
    account.refresh_token = "disconnect-refresh"
    account.token_expires_at = 1.hour.from_now
    account.save!

    stream_token = "disconnect-session"
    expect(LiveMetrics::PulsoidStreamingRegistry.activate_session(account, stream_token)).to eq(true)
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 89,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )
    LiveMetrics::PulsoidClient.expects(:revoke).with { |candidate| candidate.id == account.id }.returns(true)

    delete "/live-metrics/auth/pulsoid"

    expect(response.status).to eq(200)
    expect(LiveMetrics::ProviderAccount.find_by(id: account.id)).to be_nil
    expect(LiveMetrics::PulsoidStreamingRegistry.session_current?(account.id, stream_token)).to eq(false)
    expect(LiveMetrics::CurrentStateStore.read(account.id)).to be_nil
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
  it "maps arbitrary provider errors to a bounded code without logging descriptions" do
    LiveMetrics::SafeLog.expects(:warn).with(
      "pulsoid_oauth_provider_error",
      user_id: user.id,
      oauth_error: "oauth_error",
    )

    get "/live-metrics/auth/pulsoid/callback",
        params: {
          error: "unexpected provider value",
          error_description: "access_token=must-never-be-logged",
        }

    expect(response.status).to eq(302)
    expect(response.location).to include("error=oauth_error")
    expect(response.location).not_to include("must-never-be-logged")
  end

end
