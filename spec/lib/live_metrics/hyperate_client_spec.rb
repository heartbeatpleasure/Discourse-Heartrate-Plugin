# frozen_string_literal: true

RSpec.describe LiveMetrics::HypeRateClient do
  before do
    SiteSetting.live_metrics_hyperate_read_timeout_seconds = 15
    SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds = 45
  end

  def server_frame(payload, opcode: 0x1, fin: true)
    payload = payload.to_s.b
    first = (fin ? 0x80 : 0) | opcode
    raise "test payload too large" if payload.bytesize >= 126

    [first, payload.bytesize].pack("CC") + payload
  end

  def memory_socket(bytes)
    Class
      .new do
        def initialize(bytes)
          @bytes = bytes.dup
        end

        def readable_without_select?
          !@bytes.empty?
        end

        def readpartial(length)
          raise EOFError if @bytes.empty?

          @bytes.slice!(0, length)
        end

        def write(*)
          true
        end
      end
      .new(bytes)
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
    described_class.expects(:monotonic_now).in_sequence(sequence).returns(100.0)
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

  it "waits for the channel join reply before reporting connected" do
    socket = stub(close: nil)
    candidate = { name: "test", uri: URI.parse("wss://example.test/ws/device") }
    connected = 0
    stop = false

    described_class.stubs(:open_socket).returns(socket)
    described_class.stubs(:send_text_frame)
    described_class.stubs(:monotonic_now).returns(0.0)
    described_class
      .expects(:read_message)
      .twice
      .returns(
        { event: "phx_reply", ref: "1", payload: { status: "ok", response: {} } }.to_json,
        { event: "hr_update", payload: { hr: 81 } }.to_json,
      )

    described_class.stream_from_uri(
      "device",
      candidate,
      stop_if: -> { stop },
      on_connected: -> { connected += 1 },
      on_reading: ->(_payload) { stop = true },
    )

    expect(connected).to eq(1)
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
      .times(3)
      .returns(
        { event: "phx_reply", ref: "1", payload: { status: "ok", response: {} } }.to_json,
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

  it "uses the configured persistent-stream transport timeout" do
    expect(described_class.stream_stall_timeout_seconds).to eq(45)
  end

  it "clamps persistent-stream transport timeouts to safe bounds" do
    SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds = 1
    expect(described_class.stream_stall_timeout_seconds).to eq(10)

    SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds = 999
    expect(described_class.stream_stall_timeout_seconds).to eq(120)
  end

  it "does not treat heart-rate silence as a stall while WebSocket frames continue" do
    socket = stub(close: nil)
    candidate = { name: "test", uri: URI.parse("wss://example.test/ws/device") }
    stop = false
    frames = 0

    described_class.stubs(:open_socket).returns(socket)
    described_class.stubs(:send_text_frame)
    described_class.stubs(:monotonic_now).returns(0.0)
    described_class
      .expects(:read_message)
      .times(3)
      .returns(
        { event: "phx_reply", ref: "1", payload: { status: "ok", response: {} } }.to_json,
        { topic: "phoenix", event: "heartbeat", payload: {}, ref: nil }.to_json,
        { topic: "phoenix", event: "heartbeat", payload: {}, ref: nil }.to_json,
      )

    described_class.stream_from_uri(
      "device",
      candidate,
      stop_if: -> { stop },
      on_frame: lambda do
        frames += 1
        stop = true if frames == 3
      end,
      on_reading: ->(_payload) {},
    )

    expect(frames).to eq(3)
  end

  it "reconnects only after the WebSocket transport stops producing frames" do
    socket = stub(close: nil)
    candidate = { name: "test", uri: URI.parse("wss://example.test/ws/device") }

    described_class.stubs(:open_socket).returns(socket)
    described_class.stubs(:send_text_frame)
    described_class.stubs(:stream_stall_timeout_seconds).returns(45)
    described_class.stubs(:monotonic_now).returns(0.0, 0.0, 46.0)
    described_class.expects(:read_message).raises(Timeout::Error)

    expect do
      described_class.stream_from_uri(
        "device",
        candidate,
        stop_if: -> { false },
        on_reading: ->(_payload) {},
      )
    end.to raise_error(LiveMetrics::HypeRateClient::StreamStalled, /WebSocket frame/)
  end

  it "reads decrypted OpenSSL bytes before waiting in IO.select" do
    socket = Class.new do
      def pending
        8
      end

      def readpartial(length)
        "abcdefgh".byteslice(0, length)
      end
    end.new

    IO.expects(:select).never

    expect(described_class.read_available(socket, 100.0, max_length: 2)).to eq("ab")
  end

  it "reassembles fragmented text messages" do
    message = { event: "hr_update", payload: { hr: 88 } }.to_json
    split = message.length / 2
    bytes =
      server_frame(message.byteslice(0, split), opcode: 0x1, fin: false) +
        server_frame(message.byteslice(split..), opcode: 0x0, fin: true)

    expect(described_class.read_message(memory_socket(bytes), 100.0)).to eq(message)
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

  it "prefers the official endpoint over the legacy Phoenix socket fallback" do
    SiteSetting.live_metrics_hyperate_ws_url = "wss://app.hyperate.io/socket/websocket"

    candidates = described_class.websocket_uri_candidates("device-1")

    expect(candidates.first[:uri].path).to eq("/ws/device-1")
    expect(candidates.last[:uri].path).to eq("/socket/websocket")
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
