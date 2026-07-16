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
    SiteSetting.live_metrics_pulsoid_enabled = true
    SiteSetting.live_metrics_pulsoid_streaming_enabled = true
    SiteSetting.live_metrics_pulsoid_client_id = "client-id"
    SiteSetting.live_metrics_pulsoid_client_secret = "client-secret"
    SiteSetting.live_metrics_pulsoid_max_streams = 3
  end

  after do
    LiveMetrics::HypeRateStreamingRegistry.clear_health
    LiveMetrics::PulsoidStreamingRegistry.clear_health
  end

  it "keeps the legacy HypeRate collector alias and exposes separate collectors" do
    summary = described_class.summary

    expect(summary[:collector]).to eq(summary.dig(:collectors, :hyperate))
    expect(summary.dig(:collectors, :hyperate, :provider)).to eq("hyperate")
    expect(summary.dig(:collectors, :pulsoid, :provider)).to eq("pulsoid")
  end

  it "reports missing collector health when streaming is expected" do
    summary = described_class.summary

    expect(summary.dig(:overall, :severity)).to eq("critical")
    expect(summary[:warnings].map { |warning| warning[:code] }).to include(
      "collector_health_missing",
      "pulsoid_collector_health_missing",
    )
  end

  it "reports privacy-safe aggregate health for both providers" do
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
    LiveMetrics::PulsoidStreamingRegistry.publish_health(
      collector_started_at_ms: now_ms - 50_000,
      desired_sessions: 1,
      sessions: 1,
      connected: 1,
      reconnecting: 0,
      unauthorized: 0,
      subscription_required: 0,
      scope_required: 0,
      stalled: 0,
      oldest_event_age_seconds: 3,
      oldest_frame_age_seconds: 0,
      frames: 300,
      readings: 250,
      reconnects: 2,
      authorization_failures: 0,
      limit: 3,
      limit_reached: false,
      last_reconnect_reason: "token_refresh_due",
      last_reconnect_at_ms: now_ms - 8_000,
      last_successful_join_at_ms: now_ms - 4_000,
    )

    summary = described_class.summary
    serialized = JSON.generate(summary)

    expect(summary[:warnings].map { |warning| warning[:code] }).to include(
      "stream_limit_reached",
    )
    expect(summary.dig(:collectors, :hyperate, :last_reconnect_reason)).to eq(
      "transport_error",
    )
    expect(summary.dig(:collectors, :pulsoid, :last_reconnect_reason)).to eq(
      "token_refresh_due",
    )
    expect(summary.dig(:collectors, :pulsoid, :last_join_result)).to eq("successful")
    expect(summary.dig(:collectors, :pulsoid, :frames)).to eq(300)
    expect(serialized).not_to include(
      "heart_rate",
      "device_id",
      "provider_uid",
      "account_id",
      "username",
      "api_key",
      "access_token",
      "refresh_token",
      "email",
    )
  end

  it "reports Pulsoid scope and subscription states without account identifiers" do
    now_ms = (Time.now.to_f * 1000).to_i
    LiveMetrics::PulsoidStreamingRegistry.publish_health(
      collector_started_at_ms: now_ms - 1_000,
      desired_sessions: 2,
      sessions: 2,
      connected: 0,
      reconnecting: 0,
      unauthorized: 0,
      subscription_required: 1,
      scope_required: 1,
      stalled: 0,
      frames: 0,
      readings: 0,
      reconnects: 0,
      authorization_failures: 0,
      limit: 3,
      limit_reached: false,
      last_reconnect_reason: "scope_required",
      last_successful_join_at_ms: nil,
    )

    summary = described_class.summary
    warning_codes = summary[:warnings].map { |warning| warning[:code] }

    expect(warning_codes).to include(
      "pulsoid_subscription_required_sessions",
      "pulsoid_scope_required_sessions",
    )
    expect(summary.dig(:collectors, :pulsoid, :subscription_required)).to eq(1)
    expect(summary.dig(:collectors, :pulsoid, :scope_required)).to eq(1)
  end
end
