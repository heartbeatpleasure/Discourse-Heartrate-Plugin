# frozen_string_literal: true

RSpec.describe LiveMetrics::HypeRateClient do
  before do
    SiteSetting.live_metrics_hyperate_read_timeout_seconds = 15
  end

  it "starts the heart-rate deadline only after the WebSocket is open" do
    socket = stub(close: nil)
    candidate = { name: "test", uri: URI.parse("wss://example.test/socket") }
    sequence = sequence("connect before read deadline")

    described_class
      .expects(:open_socket)
      .with(candidate[:uri])
      .in_sequence(sequence)
      .returns(socket)
    described_class.stubs(:send_text_frame)
    described_class
      .expects(:monotonic_now)
      .in_sequence(sequence)
      .returns(100.0)
    described_class
      .expects(:read_message)
      .with(socket, 115.0)
      .in_sequence(sequence)
      .returns({ event: "hr_update", payload: { hr: 87 } }.to_json)

    expect(described_class.read_latest_heart_rate_from_uri("device", candidate)).to eq(87)
  end

  it "uses the configured HypeRate data-read timeout" do
    expect(described_class.read_timeout_seconds).to eq(15)
  end

  it "allows a longer data-read timeout while keeping connection setup bounded" do
    SiteSetting.live_metrics_hyperate_read_timeout_seconds = 30

    expect(described_class.read_timeout_seconds).to eq(30)
    expect(described_class.connect_timeout_seconds).to eq(10)
  end

  it "clamps invalid timeout values to a safe minimum" do
    SiteSetting.live_metrics_hyperate_read_timeout_seconds = 1

    expect(described_class.read_timeout_seconds).to eq(2)
    expect(described_class.connect_timeout_seconds).to eq(2)
  end
end
