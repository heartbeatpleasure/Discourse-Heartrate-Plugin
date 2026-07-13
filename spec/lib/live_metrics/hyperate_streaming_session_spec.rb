# frozen_string_literal: true

RSpec.describe LiveMetrics::HypeRateStreamingSession do
  it "tracks stalled reconnects until a fresh heart-rate event arrives" do
    session = described_class.new(database: "default", account_id: 1, fingerprint: "fingerprint")
    session.stubs(:monotonic_now).returns(100.0, 100.0)

    session.send(:record_reconnect, stalled: true)

    expect(session.stalled?).to eq(true)
    expect(session.reconnect_count).to eq(1)
    expect(session.stall_count).to eq(1)

    session.send(:record_reading_received)

    expect(session.stalled?).to eq(false)
    expect(session.last_event_age_seconds).to eq(0)
  end
end
