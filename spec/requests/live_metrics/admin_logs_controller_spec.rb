# frozen_string_literal: true

RSpec.describe "LiveMetrics admin logs", type: :request do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.live_metrics_enabled = true
    LiveMetrics::AdminEventLog.clear
  end

  after { LiveMetrics::AdminEventLog.clear }

  it "is restricted to administrators" do
    sign_in(user)

    get "/admin/plugins/live-metrics/logs.json"

    expect(response.status).not_to eq(200)
  end

  it "returns filtered privacy-safe events" do
    LiveMetrics::AdminEventLog.record(
      provider: "pulsoid",
      event: "oauth_callback",
      result: "state_mismatch",
      severity: "warning",
      client_context: "mobile_browser",
    )
    LiveMetrics::AdminEventLog.record(
      provider: "hyperate",
      event: "stream_join",
      result: "success",
      severity: "info",
      client_context: "server",
    )
    sign_in(admin)

    get "/admin/plugins/live-metrics/logs.json",
        params: { provider: "pulsoid", severity: "warning" }

    expect(response.status).to eq(200)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body["events"].length).to eq(1)
    expect(response.parsed_body.dig("events", 0, "result")).to eq("state_mismatch")

    serialized = response.body
    expect(serialized).not_to include(
      "heart_rate",
      "device_id",
      "provider_uid",
      "account_id",
      "username",
      "api_key",
      "access_token",
      "refresh_token",
    )
  end
end
