# frozen_string_literal: true

RSpec.describe LiveMetrics::OperationalAlerts do
  let(:now) { Time.zone.parse("2026-07-15 12:00:00") }
  let(:healthy_summary) do
    {
      configuration: {
        hyperate_streaming_operational: true,
      },
      accounts: {
        available: true,
        active_hyperate: 1,
      },
      collector: {
        expected: true,
        available: true,
        age_seconds: 1,
        sessions: 1,
        limit: 100,
        limit_reached: false,
      },
    }
  end

  before do
    SiteSetting.live_metrics_enabled = true
    LiveMetrics::AdminHealth.stubs(:summary).returns(healthy_summary)
    LiveMetrics::AdminEventLog.stubs(:count_since).returns(0)
  end

  it "reports no issue for healthy collector state and quiet event history" do
    expect(described_class.issues(now: now)).to be_empty
  end

  it "reports stale collector health only when active HypeRate accounts expect streaming" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:collector][:available] = false
    summary[:collector][:age_seconds] = nil
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)

    expect(described_class.issues(now: now).map { |issue| issue[:code] }).to eq(
      [:collector_health_stale],
    )
  end

  it "reports stream capacity when the configured limit remains reached" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:collector][:sessions] = 100
    summary[:collector][:limit_reached] = true
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)

    issue = described_class.issues(now: now).find { |entry| entry[:code] == :stream_limit_reached }
    expect(issue.dig(:values, :sessions)).to eq(100)
    expect(issue.dig(:values, :limit)).to eq(100)
  end

  it "requires repeated authorization failures within the bounded window" do
    LiveMetrics::AdminEventLog
      .stubs(:count_since)
      .with(
        since: now - described_class::AUTHORIZATION_WINDOW,
        result: "authorization_failed",
        severity: "error",
      )
      .returns(described_class::AUTHORIZATION_FAILURE_THRESHOLD)

    expect(described_class.issues(now: now).map { |issue| issue[:code] }).to include(
      :repeated_authorization_failures,
    )
  end

  it "does not alert for historical reconnect events when HypeRate streaming is no longer active" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:accounts][:active_hyperate] = 0
    summary[:collector][:sessions] = 0
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)
    LiveMetrics::AdminEventLog.stubs(:count_since).returns(100)

    expect(described_class.issues(now: now).map { |issue| issue[:code] }).not_to include(
      :repeated_stream_reconnects,
    )
  end

  it "scales the reconnect threshold with the number of managed sessions" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:collector][:sessions] = 10
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)

    LiveMetrics::AdminEventLog
      .stubs(:count_since)
      .with(
        since: now - described_class::RECONNECT_WINDOW,
        provider: "hyperate",
        event: "stream_reconnect",
        severity: %w[warning error],
        exclude_result: "authorization_failed",
      )
      .returns(20)

    issue = described_class.issues(now: now).find { |entry| entry[:code] == :repeated_stream_reconnects }
    expect(issue.dig(:values, :threshold)).to eq(20)
  end
end
