# frozen_string_literal: true

RSpec.describe LiveMetrics::OperationalAlerts do
  let(:now) { Time.zone.parse("2026-07-15 12:00:00") }
  let(:healthy_summary) do
    {
      configuration: {
        hyperate_streaming_operational: true,
        pulsoid_streaming_operational: true,
      },
      accounts: {
        available: true,
        active_hyperate: 1,
        active_pulsoid: 1,
      },
      collector: {
        expected: true,
        available: true,
        age_seconds: 1,
        sessions: 1,
        limit: 100,
        limit_reached: false,
      },
      collectors: {
        hyperate: {
          expected: true,
          available: true,
          age_seconds: 1,
          sessions: 1,
          limit: 100,
          limit_reached: false,
        },
        pulsoid: {
          expected: true,
          available: true,
          age_seconds: 1,
          sessions: 1,
          limit: 100,
          limit_reached: false,
        },
      },
    }
  end

  before do
    SiteSetting.live_metrics_enabled = true
    LiveMetrics::AdminHealth.stubs(:summary).returns(healthy_summary)
    LiveMetrics::AdminEventLog.stubs(:count_since).returns(0)
  end

  it "reports no issue for healthy collectors and quiet event history" do
    expect(described_class.issues(now: now)).to be_empty
  end

  it "reports stale health separately for Pulsoid" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:collectors][:pulsoid][:available] = false
    summary[:collectors][:pulsoid][:age_seconds] = nil
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)

    expect(described_class.issues(now: now).map { |issue| issue[:code] }).to eq(
      [:pulsoid_collector_health_stale],
    )
  end

  it "reports provider-specific stream capacity" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:collectors][:pulsoid][:sessions] = 100
    summary[:collectors][:pulsoid][:limit_reached] = true
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)

    issue = described_class.issues(now: now).find do |entry|
      entry[:code] == :pulsoid_stream_limit_reached
    end
    expect(issue.dig(:values, :sessions)).to eq(100)
    expect(issue.dig(:values, :limit)).to eq(100)
  end

  it "requires three Pulsoid authorization failures within thirty minutes" do
    LiveMetrics::AdminEventLog
      .stubs(:count_since)
      .with(
        since: now - described_class::AUTHORIZATION_WINDOW,
        provider: "pulsoid",
        result: "authorization_failed",
        severity: "error",
      )
      .returns(described_class::AUTHORIZATION_FAILURE_THRESHOLD)

    expect(described_class.issues(now: now).map { |issue| issue[:code] }).to include(
      :pulsoid_repeated_authorization_failures,
    )
  end

  it "requires repeated Pulsoid subscription and scope failures" do
    LiveMetrics::AdminEventLog
      .stubs(:count_since)
      .with(
        since: now - described_class::SUBSCRIPTION_WINDOW,
        provider: "pulsoid",
        result: "subscription_required",
        severity: %w[warning error],
      )
      .returns(described_class::SUBSCRIPTION_REQUIRED_THRESHOLD)
    LiveMetrics::AdminEventLog
      .stubs(:count_since)
      .with(
        since: now - described_class::SCOPE_WINDOW,
        provider: "pulsoid",
        result: "scope_required",
        severity: %w[warning error],
      )
      .returns(described_class::SCOPE_REQUIRED_THRESHOLD)

    codes = described_class.issues(now: now).map { |issue| issue[:code] }
    expect(codes).to include(:pulsoid_subscription_required, :pulsoid_scope_required)
  end

  it "does not alert on historical Pulsoid events when no active account expects streaming" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:accounts][:active_pulsoid] = 0
    summary[:collectors][:pulsoid][:sessions] = 0
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)
    LiveMetrics::AdminEventLog.stubs(:count_since).returns(100)

    expect(described_class.issues(now: now).map { |issue| issue[:code] }).not_to include(
      :pulsoid_repeated_authorization_failures,
      :pulsoid_subscription_required,
      :pulsoid_scope_required,
      :pulsoid_repeated_stream_reconnects,
    )
  end

  it "scales the Pulsoid reconnect threshold with managed sessions" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:collectors][:pulsoid][:sessions] = 10
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)

    LiveMetrics::AdminEventLog
      .stubs(:count_since)
      .with(
        since: now - described_class::RECONNECT_WINDOW,
        provider: "pulsoid",
        event: "stream_reconnect",
        severity: %w[warning error],
        exclude_result: ["authorization_failed", "subscription_required", "scope_required"],
      )
      .returns(20)

    issue = described_class.issues(now: now).find do |entry|
      entry[:code] == :pulsoid_repeated_stream_reconnects
    end
    expect(issue.dig(:values, :threshold)).to eq(20)
  end

  it "preserves the existing HypeRate issue codes" do
    summary = Marshal.load(Marshal.dump(healthy_summary))
    summary[:collectors][:hyperate][:available] = false
    summary[:collectors][:hyperate][:age_seconds] = nil
    LiveMetrics::AdminHealth.stubs(:summary).returns(summary)

    expect(described_class.issues(now: now).map { |issue| issue[:code] }).to include(
      :collector_health_stale,
    )
  end
end
