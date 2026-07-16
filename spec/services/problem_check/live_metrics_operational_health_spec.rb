# frozen_string_literal: true

RSpec.describe ProblemCheck::LiveMetricsOperationalHealth do
  it "uses a persistent high-priority scheduled check instead of emitting one notice per request" do
    expect(described_class.priority).to eq("high")
    expect(described_class.perform_every).to eq(10.minutes)
    expect(described_class.max_retries).to eq(0)
    expect(described_class.max_blips).to eq(1)
  end

  it "returns no problem while there are no persistent operational issues" do
    LiveMetrics::OperationalAlerts.stubs(:issues).returns([])

    expect(described_class.new.call).to be_nil
  end

  it "re-enables a dismissed warning only after the problem has recovered" do
    tracker = mock
    tracker.stubs(:passing?).returns(true)
    tracker.stubs(:ignored?).returns(true)
    tracker.expects(:watch!).once

    check = described_class.new
    check.stubs(:tracker).returns(tracker)
    check.send(:rearm_after_recovery)
  end

  it "keeps a dismissed warning suppressed while the same problem is still failing" do
    tracker = mock
    tracker.stubs(:passing?).returns(false)
    tracker.stubs(:ignored?).returns(true)
    tracker.expects(:watch!).never

    check = described_class.new
    check.stubs(:tracker).returns(tracker)
    check.send(:rearm_after_recovery)
  end

  it "returns one aggregated problem for multiple operational issues" do
    LiveMetrics::OperationalAlerts.stubs(:issues).returns(
      [
        {
          code: :stream_limit_reached,
          values: { sessions: 100, limit: 100 },
        },
        {
          code: :repeated_authorization_failures,
          values: { count: 4, window_minutes: 30 },
        },
      ],
    )

    problem = described_class.new.call

    expect(problem).to be_present
    expect(problem.identifier).to eq(:live_metrics_operational_health)
    expect(problem.details[:issue_codes]).to eq(
      "stream_limit_reached,repeated_authorization_failures",
    )
    expect(problem.details[:issues]).to include("<ul>", "<li>")
  end
  it "renders Pulsoid issues through the same aggregated admin notice" do
    LiveMetrics::OperationalAlerts.stubs(:issues).returns(
      [
        {
          code: :pulsoid_subscription_required,
          values: { count: 3, window_minutes: 30 },
        },
        {
          code: :pulsoid_repeated_stream_reconnects,
          values: { count: 8, threshold: 8, window_minutes: 30 },
        },
      ],
    )

    problem = described_class.new.call

    expect(problem.details[:issue_codes]).to eq(
      "pulsoid_subscription_required,pulsoid_repeated_stream_reconnects",
    )
    expect(problem.details[:issues]).to include("Pulsoid")
  end

end
