# frozen_string_literal: true

RSpec.describe LiveMetrics::HypeRateStreamingSession do
  it "tracks transport stalls and clears them after a successful channel join" do
    session = described_class.new(database: "default", account_id: 1, fingerprint: "fingerprint")

    session.send(:record_reconnect, stalled: true)

    expect(session.stalled?).to eq(true)
    expect(session.reconnect_count).to eq(1)
    expect(session.stall_count).to eq(1)

    session.send(:record_connected)

    expect(session.stalled?).to eq(false)
    expect(session.connected?).to eq(true)
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
end
