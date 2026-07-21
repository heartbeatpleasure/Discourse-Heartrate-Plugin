# frozen_string_literal: true

RSpec.describe LiveMetrics::HypeRateStreamingSession do
  it "tracks transport stalls and clears them after a successful channel join" do
    session = described_class.new(database: "default", account_id: 1, fingerprint: "fingerprint")

    session.stubs(:current_time_ms).returns(1_000, 2_000)
    session.send(:record_reconnect, reason: :transport_stalled, stalled: true)

    expect(session.stalled?).to eq(true)
    expect(session.reconnect_count).to eq(1)
    expect(session.stall_count).to eq(1)
    expect(session.last_reconnect_reason).to eq("transport_stalled")
    expect(session.last_reconnect_at_ms).to eq(1_000)

    session.send(:record_connected)

    expect(session.stalled?).to eq(false)
    expect(session.connected?).to eq(true)
    expect(session.last_successful_join_at_ms).to eq(2_000)
  end

  it "records bounded retry reasons without changing the reconnect counter" do
    session = described_class.new(database: "default", account_id: 1, fingerprint: "fingerprint")
    session.stubs(:current_time_ms).returns(3_000)

    session.send(:record_retry_reason, :authorization_failed)

    expect(session.last_reconnect_reason).to eq("authorization_failed")
    expect(session.last_reconnect_at_ms).to eq(3_000)
    expect(session.reconnect_count).to eq(0)
  end

  it "tracks frames and heart-rate readings independently" do
    session = described_class.new(database: "default", account_id: 1, fingerprint: "fingerprint")
    session.stubs(:monotonic_now).returns(100.0, 101.0, 103.0, 104.0)

    session.send(:record_frame_received)
    session.send(:record_frame_received)
    session.send(:record_reading_received)

    expect(session.frame_count).to eq(2)
    expect(session.reading_count).to eq(1)
    expect(session.last_frame_age_seconds).to eq(3)
    expect(session.last_event_age_seconds).to eq(1)
  end

  it "tracks expected no-reading recovery without filling the admin event log" do
    session = described_class.new(database: "default", account_id: 1, fingerprint: "fingerprint")
    session.stubs(:current_time_ms).returns(4_000, 5_000)
    LiveMetrics::AdminEventLog.expects(:record).never

    session.send(:record_reconnect, reason: :no_data, log_event: false)
    session.send(:record_connected, log_event: false)

    expect(session.reconnect_count).to eq(1)
    expect(session.last_reconnect_reason).to eq("no_data")
    expect(session.connected?).to eq(true)
    expect(session.last_successful_join_at_ms).to eq(5_000)
  end

end
