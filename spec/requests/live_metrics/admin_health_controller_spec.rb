# frozen_string_literal: true

RSpec.describe "LiveMetrics admin health", type: :request do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_hyperate_enabled = true
    SiteSetting.live_metrics_hyperate_streaming_enabled = true
    SiteSetting.live_metrics_hyperate_api_key = "test-key"
    SiteSetting.live_metrics_hyperate_ws_url = "wss://app.hyperate.io/ws/:deviceId"
  end

  after { LiveMetrics::HypeRateStreamingRegistry.clear_health }

  it "is restricted to administrators" do
    sign_in(user)

    get "/admin/plugins/live-metrics/health.json"

    expect(response.status).not_to eq(200)
  end

  it "returns aggregate health without reading values or provider identifiers" do
    now_ms = (Time.now.to_f * 1000).to_i
    LiveMetrics::HypeRateStreamingRegistry.publish_health(
      collector_started_at_ms: now_ms - 60_000,
      sessions: 1,
      connected: 1,
      reconnecting: 0,
      unauthorized: 0,
      stalled: 0,
      oldest_event_age_seconds: 1,
      oldest_frame_age_seconds: 1,
      frames: 40,
      readings: 35,
      reconnects: 0,
      stalls: 0,
      limit: 100,
      limit_reached: false,
      last_reconnect_reason: "none",
      last_reconnect_at_ms: nil,
      last_successful_join_at_ms: now_ms - 30_000,
    )
    sign_in(admin)

    get "/admin/plugins/live-metrics/health.json"

    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("collector", "connected")).to eq(1)
    expect(response.parsed_body.dig("collector", "last_join_result")).to eq("successful")
    expect(response.headers["Cache-Control"]).to include("no-store")

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
