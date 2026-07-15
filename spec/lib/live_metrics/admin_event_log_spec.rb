# frozen_string_literal: true

RSpec.describe LiveMetrics::AdminEventLog do
  before { described_class.clear }
  after { described_class.clear }

  it "stores only bounded operational fields" do
    described_class.record(
      provider: "pulsoid",
      event: "oauth_callback",
      result: "state_mismatch",
      severity: "warning",
      client_context: "mobile_browser",
    )

    event = described_class.recent.first
    expect(event).to include(
      provider: "pulsoid",
      event: "oauth_callback",
      result: "state_mismatch",
      severity: "warning",
      client_context: "mobile_browser",
    )
    expect(event.keys).to contain_exactly(
      :id,
      :occurred_at,
      :occurred_at_ms,
      :severity,
      :provider,
      :event,
      :result,
      :client_context,
    )
  end

  it "counts only matching events inside a bounded time window" do
    described_class.record(
      provider: "hyperate",
      event: "stream_reconnect",
      result: "transport_error",
      severity: "warning",
      occurred_at: 10.minutes.ago,
    )
    described_class.record(
      provider: "hyperate",
      event: "stream_reconnect",
      result: "authorization_failed",
      severity: "error",
      occurred_at: 5.minutes.ago,
    )
    described_class.record(
      provider: "hyperate",
      event: "stream_reconnect",
      result: "transport_error",
      severity: "warning",
      occurred_at: 45.minutes.ago,
    )

    expect(
      described_class.count_since(
        since: 30.minutes.ago,
        provider: "hyperate",
        event: "stream_reconnect",
        severity: %w[warning error],
        exclude_result: "authorization_failed",
      ),
    ).to eq(1)
  end

  it "filters events by provider and severity" do
    described_class.record(
      provider: "pulsoid",
      event: "oauth_start",
      result: "redirected",
      severity: "info",
    )
    described_class.record(
      provider: "hyperate",
      event: "stream_reconnect",
      result: "transport_error",
      severity: "warning",
    )

    expect(described_class.recent(provider: "pulsoid").map { |event| event[:provider] }).to eq(
      ["pulsoid"],
    )
    expect(described_class.recent(severity: "warning").map { |event| event[:provider] }).to eq(
      ["hyperate"],
    )
  end

  it "removes events older than the retention window" do
    described_class.record(
      provider: "system",
      event: "stream_capacity",
      result: "limit_reached",
      severity: "warning",
      occurred_at: 8.days.ago,
    )

    expect(described_class.recent).to be_empty
  end


  it "sanitizes unsupported values instead of storing free text" do
    described_class.record(
      provider: "provider-with-user-data",
      event: "custom event with details",
      result: "free-form provider response",
      severity: "fatal",
      client_context: "full user agent",
    )

    expect(described_class.recent.first).to include(
      provider: "system",
      event: "unknown",
      result: "unknown",
      severity: "info",
      client_context: "unknown",
    )
  end

  it "keeps only the configured maximum number of events" do
    (described_class::MAX_EVENTS + 1).times do
      described_class.record(
        provider: "system",
        event: "stream_capacity",
        result: "limit_reached",
      )
    end

    expect(described_class.total_count).to eq(described_class::MAX_EVENTS)
    expect(described_class.recent(limit: described_class::MAX_EVENTS).length).to eq(
      described_class::MAX_LIMIT,
    )
  end

  it "classifies only a broad browser context" do
    request = Struct.new(:user_agent)

    expect(
      described_class.client_context_for(
        request.new("Mozilla/5.0 (Linux; Android 14; wv) AppleWebKit/537.36"),
      ),
    ).to eq("embedded_webview")
    expect(
      described_class.client_context_for(
        request.new("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0) Mobile Safari/604.1"),
      ),
    ).to eq("mobile_browser")
    expect(
      described_class.client_context_for(
        request.new("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/150 Safari/537.36"),
      ),
    ).to eq("desktop_browser")
  end
end
