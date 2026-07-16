# frozen_string_literal: true

RSpec.describe LiveMetrics::PulsoidStreamingClient do
  before do
    SiteSetting.live_metrics_pulsoid_enabled = true
    SiteSetting.live_metrics_pulsoid_ws_url =
      "wss://dev.pulsoid.net/api/v1/data/real_time"
    SiteSetting.live_metrics_pulsoid_stream_transport_timeout_seconds = 45
  end

  def server_frame(payload, opcode: 0x1, fin: true, masked: false)
    payload = payload.to_s.b
    first = (fin ? 0x80 : 0) | opcode
    second = masked ? 0x80 : 0
    raise "test payload too large" if payload.bytesize >= 126

    [first, second | payload.bytesize].pack("CC") + payload
  end

  def memory_socket(bytes)
    Class
      .new do
        attr_reader :writes

        def initialize(bytes)
          @bytes = bytes.dup
          @writes = []
        end

        def readable_without_select?
          !@bytes.empty?
        end

        def readpartial(length)
          raise EOFError if @bytes.empty?

          @bytes.slice!(0, length)
        end

        def write(value)
          @writes << value
          value.bytesize
        end
      end
      .new(bytes)
  end

  it "treats a WebSocket URL containing credentials as non-operational" do
    SiteSetting.live_metrics_pulsoid_ws_url =
      "wss://dev.pulsoid.net/api/v1/data/real_time?access_token=must-not-be-used"

    expect(described_class.configured?).to eq(false)
  end

  it "normalizes a valid Pulsoid reading without storing history" do
    measured_at = (Time.zone.now.to_f * 1000).to_i
    payload = described_class.normalize_message(
      { measured_at: measured_at, data: { heart_rate: 87 } }.to_json,
    )

    expect(payload).to include(
      status: "live",
      heart_rate: 87,
      measured_at_ms: measured_at,
    )
  end

  it "ignores invalid BPM, timestamps, JSON and non-object payloads" do
    now_ms = (Time.zone.now.to_f * 1000).to_i
    invalid = [
      { measured_at: now_ms, data: { heart_rate: 0 } }.to_json,
      { measured_at: now_ms, data: { heart_rate: 260 } }.to_json,
      { measured_at: "#{now_ms}", data: { heart_rate: 80 } }.to_json,
      { measured_at: now_ms, data: { heart_rate: "80" } }.to_json,
      { measured_at: 1, data: { heart_rate: 80 } }.to_json,
      { measured_at: now_ms + 10.minutes.to_i * 1000, data: { heart_rate: 80 } }.to_json,
      "not-json",
      [].to_json,
    ]

    invalid.each { |message| expect(described_class.normalize_message(message)).to be_nil }
  end

  it "accepts only a cryptographically valid WebSocket upgrade" do
    key = Base64.strict_encode64("0123456789abcdef")
    accept = Base64.strict_encode64(
      Digest::SHA1.digest("#{key}#{described_class::WEBSOCKET_GUID}"),
    )
    response = <<~HTTP.gsub("\n", "\r\n")
      HTTP/1.1 101 Switching Protocols
      Upgrade: websocket
      Connection: keep-alive, Upgrade
      Sec-WebSocket-Accept: #{accept}

    HTTP

    expect { described_class.verify_websocket_handshake!(response, key) }.not_to raise_error

    expect do
      described_class.verify_websocket_handshake!(response.sub(accept, "invalid"), key)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError, /accept header/)

    expect do
      described_class.verify_websocket_handshake!(response.sub("Upgrade: websocket", "Upgrade: h2c"), key)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError, /upgrade headers/)

    expect do
      described_class.verify_websocket_handshake!(response.sub("Connection: keep-alive, Upgrade", "Connection: keep-alive"), key)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError, /upgrade headers/)

    expect do
      described_class.verify_websocket_handshake!(response.sub("101 Switching Protocols", "200 OK"), key)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError, /upgrade status/)
  end

  it "rejects oversized handshake headers" do
    socket = stub
    described_class.stubs(:read_available).returns(
      "A" * (described_class::MAX_HTTP_HEADER_BYTES + 1),
    )

    expect do
      described_class.read_http_response(socket)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError, /safe size limit/)
  end

  it "preserves WebSocket bytes delivered with the HTTP 101 response" do
    socket = stub
    response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".b
    frame = server_frame("{}")
    described_class.stubs(:read_available).returns(response + frame)

    header, remaining = described_class.read_http_response(socket)

    expect(header).to eq(response)
    expect(remaining).to eq(frame)
  end

  it "reassembles fragmented text around ping frames and sends a masked pong" do
    message = { measured_at: 1_700_000_000_000, data: { heart_rate: 88 } }.to_json
    split = message.bytesize / 2
    socket = memory_socket(
      server_frame(message.byteslice(0, split), opcode: 0x1, fin: false) +
        server_frame("ping", opcode: 0x9) +
        server_frame(message.byteslice(split..), opcode: 0x0, fin: true),
    )

    expect(described_class.read_message(socket, described_class.monotonic_now + 1)).to eq(message)
    expect(socket.writes.length).to eq(1)
    expect(socket.writes.first.getbyte(0) & 0x0f).to eq(0xA)
    expect(socket.writes.first.getbyte(1) & 0x80).to eq(0x80)
  end

  it "rejects masked server frames and messages over the configured limit" do
    masked_socket = memory_socket(server_frame("x", masked: true))
    expect do
      described_class.read_frame(masked_socket, described_class.monotonic_now + 1)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError, /must not be masked/)

    oversized_header = [0x81, 127].pack("CC") + [described_class::MAX_MESSAGE_BYTES + 1].pack("Q>")
    oversized_socket = memory_socket(oversized_header)
    expect do
      described_class.read_frame(oversized_socket, described_class.monotonic_now + 1)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError, /safe size limit/)
  end

  it "handles valid close frames and rejects malformed close payloads" do
    valid_socket = memory_socket(server_frame([1000].pack("n"), opcode: 0x8))
    expect do
      described_class.read_message(valid_socket, described_class.monotonic_now + 1)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::StreamClosed)
    expect(valid_socket.writes).not_to be_empty

    invalid_socket = memory_socket(server_frame("x", opcode: 0x8))
    expect do
      described_class.read_message(invalid_socket, described_class.monotonic_now + 1)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError, /close payload/)
  end

  it "rejects credentials in the URL and line breaks in bearer tokens" do
    unsafe_uri = URI.parse(
      "wss://dev.pulsoid.net/api/v1/data/real_time?access_token=secret",
    )
    expect do
      described_class.send(:reject_sensitive_query!, unsafe_uri)
    end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError)

    ["token\r\nInjected: yes", "token with space"].each do |unsafe_token|
      expect do
        described_class.send(:validated_access_token!, unsafe_token)
      end.to raise_error(LiveMetrics::PulsoidStreamingClient::ProtocolError)
    end
  end
end
