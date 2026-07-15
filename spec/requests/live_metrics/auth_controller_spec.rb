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
