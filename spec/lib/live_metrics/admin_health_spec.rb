# frozen_string_literal: true

RSpec.describe LiveMetrics::AdminHealth do
  before do
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.live_metrics_hyperate_enabled = true
    SiteSetting.live_metrics_hyperate_streaming_enabled = true
    SiteSetting.live_metrics_hyperate_api_key = "test-key"
    SiteSetting.live_metrics_hyperate_ws_url = "wss://app.hyperate.io/ws/:deviceId"
    SiteSetting.live_metrics_hyperate_max_streams = 2
  end

  after { LiveMetrics::HypeRateStreamingRegistry.clear_health }

  it "reports missing collector health when streaming is expected" do
    summary = described_class.summary

    expect(summary.dig(:overall, :severity)).to eq("critical")
    expect(summary[:warnings].map { |warning| warning[:code] }).to include(
      "collector_health_missing",
    )
  end

  it "reports capacity warnings using aggregate privacy-safe data" do
    now_ms = (Time.now.to_f * 1000).to_i
    LiveMetrics::HypeRateStreamingRegistry.publish_health(
      collector_started_at_ms: now_ms - 60_000,
      sessions: 2,
      connected: 2,
      reconnecting: 0,
      unauthorized: 0,
      stalled: 0,
      oldest_event_age_seconds: 2,
      oldest_frame_age_seconds: 1,
      frames: 200,
      readings: 180,
      reconnects: 1,
      stalls: 0,
      limit: 2,
      limit_reached: true,
      last_reconnect_reason: "transport_error",
      last_reconnect_at_ms: now_ms - 10_000,
      last_successful_join_at_ms: now_ms - 5_000,
    )

    summary = described_class.summary
    serialized = JSON.generate(summary)

    expect(summary.dig(:overall, :severity)).to eq("warning")
    expect(summary[:warnings].map { |warning| warning[:code] }).to include(
      "stream_limit_reached",
    )
    expect(summary.dig(:collector, :last_reconnect_reason)).to eq("transport_error")
    expect(summary.dig(:collector, :last_join_result)).to eq("successful")
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
