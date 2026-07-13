# frozen_string_literal: true

RSpec.describe LiveMetrics::HypeRateClient do
  before do
    SiteSetting.live_metrics_hyperate_read_timeout_seconds = 15
    SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds = 25
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

  it "keeps one socket open for multiple heart-rate events" do
    socket = stub(close: nil)
    candidate = { name: "test", uri: URI.parse("wss://example.test/ws/device") }
    stop = false
    readings = []

    described_class.stubs(:open_socket).returns(socket)
    described_class.stubs(:send_text_frame)
    described_class.stubs(:monotonic_now).returns(0.0)
    described_class
      .expects(:read_message)
      .with(socket, 15.0)
      .twice
      .returns(
        { event: "hr_update", payload: { hr: 81 } }.to_json,
        { event: "hr_update", payload: { hr: 82 } }.to_json,
      )

    described_class.stream_from_uri(
      "device",
      candidate,
      stop_if: -> { stop },
      on_reading: lambda do |payload|
        readings << payload[:heart_rate]
        stop = true if readings.length == 2
      end,
    )

    expect(readings).to eq([81, 82])
  end


  it "uses the configured persistent-stream inactivity timeout" do
    expect(described_class.stream_stall_timeout_seconds).to eq(25)
  end

  it "clamps persistent-stream inactivity timeouts to safe bounds" do
    SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds = 1
    expect(described_class.stream_stall_timeout_seconds).to eq(10)

    SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds = 999
    expect(described_class.stream_stall_timeout_seconds).to eq(120)
  end

  it "reconnects a connected stream after heart-rate events stop arriving" do
    socket = stub(close: nil)
    candidate = { name: "test", uri: URI.parse("wss://example.test/ws/device") }

    described_class.stubs(:open_socket).returns(socket)
    described_class.stubs(:send_text_frame)
    described_class.stubs(:stream_stall_timeout_seconds).returns(25)
    described_class.stubs(:monotonic_now).returns(0.0, 0.0, 25.0)
    described_class
      .expects(:read_message)
      .with(socket, 15.0)
      .raises(Timeout::Error)

    expect do
      described_class.stream_from_uri(
        "device",
        candidate,
        stop_if: -> { false },
        on_reading: ->(_payload) {},
      )
    end.to raise_error(LiveMetrics::HypeRateClient::StreamStalled, /25 seconds/)
  end

  it "resets the inactivity deadline after each valid heart-rate event" do
    socket = stub(close: nil)
    candidate = { name: "test", uri: URI.parse("wss://example.test/ws/device") }
    stop = false
    readings = []

    described_class.stubs(:open_socket).returns(socket)
    described_class.stubs(:send_text_frame)
    described_class.stubs(:stream_stall_timeout_seconds).returns(25)
    described_class.stubs(:monotonic_now).returns(0.0, 0.0, 10.0, 15.0, 16.0)
    described_class
      .expects(:read_message)
      .with(socket, 15.0)
      .returns({ event: "hr_update", payload: { hr: 81 } }.to_json)
    described_class
      .expects(:read_message)
      .with(socket, 30.0)
      .returns({ event: "hr_update", payload: { hr: 82 } }.to_json)

    described_class.stream_from_uri(
      "device",
      candidate,
      stop_if: -> { stop },
      on_reading: lambda do |payload|
        readings << payload[:heart_rate]
        stop = true if readings.length == 2
      end,
    )

    expect(readings).to eq([81, 82])
  end

  it "builds the documented HypeRate heartbeat payload" do
    payload = JSON.parse(described_class.heartbeat_message)

    expect(payload["event"]).to eq("ping")
    expect(payload.dig("payload", "timestamp")).to be_a(Integer)
  end

  it "builds the official device-path WebSocket URL" do
    SiteSetting.live_metrics_hyperate_api_key = "secret"

    uri = described_class.websocket_uri_for_base(
      "wss://app.hyperate.io/ws/:deviceId",
      "device-1",
    )

    expect(uri.path).to eq("/ws/device-1")
    expect(URI.decode_www_form(uri.query)).to include(["token", "secret"])
  end
  it "preserves WebSocket bytes received with the HTTP upgrade response" do
    socket = stub
    response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".b
    frame = "\x81\x02{}".b
    described_class.stubs(:connect_timeout_seconds).returns(10)
    described_class.stubs(:read_available).returns(response + frame)

    header, remaining = described_class.read_http_response(socket)

    expect(header).to eq(response)
    expect(remaining).to eq(frame)
  end

end
