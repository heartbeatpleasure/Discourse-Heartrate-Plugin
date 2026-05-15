# frozen_string_literal: true

require "base64"
require "cgi"
require "json"
require "openssl"
require "securerandom"
require "socket"
require "timeout"
require "uri"

module ::LiveMetrics
  class HypeRateClient
    USER_AGENT = "Discourse Heartrate HypeRate/0.1"
    DEFAULT_WS_URL = "wss://app.hyperate.io/socket/websocket"
    DEVICE_PATH_WS_URL = "wss://app.hyperate.io/ws"
    LEGACY_SOCKET_PATH = "/socket/websocket"
    DEVICE_SOCKET_PATH = "/ws"
    DEFAULT_ORIGIN = "https://app.hyperate.io"
    MAX_DEVICE_ID_LENGTH = 128

    class Error < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end
    end

    class Unauthorized < Error; end
    class NoHeartRateData < Error; end

    def self.configured?
      SiteSetting.live_metrics_hyperate_enabled && SiteSetting.live_metrics_hyperate_api_key.to_s.strip.present?
    end

    def self.enabled?
      SiteSetting.live_metrics_hyperate_enabled
    end

    def self.normalize_device_id(value)
      value.to_s.strip[0, MAX_DEVICE_ID_LENGTH]
    end

    def self.valid_device_id?(value)
      id = normalize_device_id(value)
      id.present? && id.match?(/\A[a-zA-Z0-9_\-:.]+\z/)
    end

    def self.latest(account)
      return { status: "unavailable", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: "HypeRate is not configured." } unless configured?

      device_id = normalize_device_id(account.provider_uid)
      return { status: "no_data", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: "Missing HypeRate device ID." } if device_id.blank?

      cache_key = "live_metrics:hyperate:latest:v1:#{account.id}:#{device_id}:#{account.updated_at.to_i}"
      Discourse.cache.fetch(cache_key, expires_in: SiteSetting.live_metrics_api_cache_seconds.seconds) do
        normalize_latest_response(read_latest_heart_rate(device_id))
      end
    rescue Unauthorized => e
      account.update_columns(last_error: "unauthorized", updated_at: Time.zone.now) rescue nil
      { status: "unauthorized", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: unauthorized_message(e) }
    rescue NoHeartRateData => e
      { status: "no_data", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: e.message }
    rescue => e
      Rails.logger.warn("[live_metrics] HypeRate latest failed account_id=#{account.id} device_id=#{device_id} error=#{e.class}: #{e.message}")
      { status: "unavailable", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: "HypeRate data is temporarily unavailable." }
    end

    def self.read_latest_heart_rate(device_id)
      last_error = nil

      websocket_uri_candidates(device_id).each do |candidate|
        begin
          return read_latest_heart_rate_from_uri(device_id, candidate)
        rescue Unauthorized, Error => e
          last_error = e
          Rails.logger.warn("[live_metrics] HypeRate WebSocket candidate failed endpoint=#{candidate[:name]} status=#{e.respond_to?(:status) ? e.status : nil} error=#{e.class}: #{e.message}")
          next if fallback_allowed_for?(e)
          raise
        rescue NoHeartRateData => e
          last_error = e
          # If the socket opened successfully but did not produce a heart-rate
          # update, another endpoint is unlikely to help. Keep this as a clean
          # no-data state rather than presenting it as an authorization error.
          raise
        end
      end

      raise(last_error || NoHeartRateData.new("No HypeRate heart-rate update was received."))
    end

    def self.read_latest_heart_rate_from_uri(device_id, candidate)
      timeout_seconds = SiteSetting.live_metrics_hyperate_read_timeout_seconds.to_i
      timeout_seconds = 4 if timeout_seconds <= 0
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      socket = nil

      Timeout.timeout(timeout_seconds + 2) do
        socket = open_socket(candidate[:uri])
        send_text_frame(socket, join_message(device_id))

        loop do
          message = read_message(socket, deadline)
          next if message.blank?

          payload = parse_json(message)
          event = payload["event"].to_s

          if event == "phx_reply" && payload.dig("payload", "status").to_s == "error"
            reason = payload.dig("payload", "response", "reason").presence || payload.dig("payload", "response", "message").presence || "HypeRate rejected the channel join."
            raise Unauthorized.new(reason) if reason.to_s.match?(/auth|token|unauthor|forbid|reject|invalid/i)
            raise NoHeartRateData.new(reason.to_s)
          end

          if event == "hr_update"
            heart_rate = payload.dig("payload", "hr")
            return heart_rate if valid_heart_rate?(heart_rate)
          end
        end
      end
    rescue Timeout::Error
      raise NoHeartRateData.new("No HypeRate heart-rate update was received before the request timed out.")
    ensure
      begin
        send_text_frame(socket, leave_message(device_id)) if socket
      rescue
        nil
      end

      begin
        socket&.close
      rescue
        nil
      end
    end

    def self.normalize_latest_response(heart_rate)
      now = Time.zone.now
      {
        status: "live",
        heart_rate: heart_rate.to_i,
        measured_at: now.iso8601,
        measured_at_ms: (now.to_f * 1000).to_i,
        age_seconds: 0
      }
    end

    def self.open_socket(uri)
      tcp = Socket.tcp(uri.host, uri.port || 443, connect_timeout: SiteSetting.live_metrics_hyperate_read_timeout_seconds.to_i.clamp(2, 10))

      socket = tcp
      if uri.scheme == "wss"
        context = OpenSSL::SSL::SSLContext.new
        context.set_params
        socket = OpenSSL::SSL::SSLSocket.new(tcp, context)
        socket.hostname = uri.host if socket.respond_to?(:hostname=)
        socket.sync_close = true
        socket.connect
      end

      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      path = uri.path.presence || "/"
      path = "#{path}?#{uri.query}" if uri.query.present?

      request = [
        "GET #{path} HTTP/1.1",
        "Host: #{uri.host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}",
        "Sec-WebSocket-Version: 13",
        "Origin: #{DEFAULT_ORIGIN}",
        "User-Agent: #{USER_AGENT}",
        "",
        ""
      ].join("\r\n")

      socket.write(request)
      response = read_http_response(socket)
      status = response[/\AHTTP\/\d\.\d\s+(\d+)/, 1].to_i

      raise Unauthorized.new("HypeRate authorization failed", status: status, body: safe_body(response)) if [401, 403].include?(status)
      raise Error.new("HypeRate WebSocket handshake failed", status: status, body: safe_body(response)) unless status == 101

      socket
    rescue
      begin
        socket&.close
      rescue
        nil
      end
      begin
        tcp&.close
      rescue
        nil
      end
      raise
    end

    def self.websocket_uri_candidates(device_id)
      configured_base = SiteSetting.live_metrics_hyperate_ws_url.to_s.strip
      bases = []
      bases << configured_base if configured_base.present?
      bases << DEFAULT_WS_URL
      bases << DEVICE_PATH_WS_URL

      bases
        .compact
        .map(&:strip)
        .select { |base| base.start_with?("wss://", "ws://") }
        .uniq
        .map { |base| { name: endpoint_name(base), uri: websocket_uri_for_base(base, device_id) } }
    end

    def self.websocket_uri_for_base(base, device_id)
      base = base.chomp("/")
      token = SiteSetting.live_metrics_hyperate_api_key.to_s.strip

      if base.include?(":deviceId")
        uri = URI.parse(base.gsub(":deviceId", CGI.escape(device_id)))
      elsif phoenix_socket_base?(base)
        uri = URI.parse(base)
      else
        uri = URI.parse("#{base}/#{CGI.escape(device_id)}")
      end

      existing_query = URI.decode_www_form(uri.query.to_s) rescue []
      existing_query.reject! { |key, _| key == "token" }
      existing_query << ["token", token]
      uri.query = URI.encode_www_form(existing_query)
      uri
    end

    def self.endpoint_name(base)
      phoenix_socket_base?(base) ? "phoenix_socket" : "device_path"
    end

    def self.phoenix_socket_base?(base)
      path = URI.parse(base).path.to_s rescue ""
      path == LEGACY_SOCKET_PATH || path.end_with?(LEGACY_SOCKET_PATH)
    end

    def self.fallback_allowed_for?(error)
      return true if error.is_a?(Unauthorized) && [401, 403].include?(error.status.to_i)
      return true if error.is_a?(Error) && error.status.to_i != 101

      false
    end

    def self.join_message(device_id)
      {
        topic: "hr:#{device_id}",
        event: "phx_join",
        payload: {},
        ref: "1"
      }.to_json
    end

    def self.leave_message(device_id)
      {
        topic: "hr:#{device_id}",
        event: "phx_leave",
        payload: {},
        ref: Time.now.to_i.to_s
      }.to_json
    end

    def self.read_http_response(socket)
      buffer = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SiteSetting.live_metrics_hyperate_read_timeout_seconds.to_i.clamp(2, 10)

      until buffer.include?("\r\n\r\n")
        chunk = read_available(socket, deadline)
        break if chunk.blank?
        buffer << chunk
      end

      buffer
    end

    def self.read_message(socket, deadline)
      loop do
        header = read_exact(socket, 2, deadline)
        first = header.getbyte(0)
        second = header.getbyte(1)
        opcode = first & 0x0f
        masked = (second & 0x80) != 0
        length = second & 0x7f

        length = read_exact(socket, 2, deadline).unpack1("n") if length == 126
        length = read_exact(socket, 8, deadline).unpack1("Q>") if length == 127

        mask = masked ? read_exact(socket, 4, deadline).bytes : nil
        payload = length.positive? ? read_exact(socket, length, deadline) : +""

        if masked && mask
          bytes = payload.bytes
          payload = bytes.each_with_index.map { |byte, index| (byte ^ mask[index % 4]).chr }.join
        end

        case opcode
        when 0x1
          return payload.force_encoding("UTF-8")
        when 0x8
          raise NoHeartRateData.new("HypeRate closed the WebSocket before sending heart-rate data.")
        when 0x9
          send_frame(socket, opcode: 0xA, payload: payload)
        else
          # Ignore binary, continuation and pong frames for this read-only PoC.
        end
      end
    end

    def self.send_text_frame(socket, text)
      send_frame(socket, opcode: 0x1, payload: text.to_s) if socket
    end

    def self.send_frame(socket, opcode:, payload: "")
      payload = payload.b
      bytes = [0x80 | opcode]
      mask_bit = 0x80
      length = payload.bytesize

      if length < 126
        bytes << (mask_bit | length)
      elsif length <= 65_535
        bytes << (mask_bit | 126)
        bytes.concat([length].pack("n").bytes)
      else
        bytes << (mask_bit | 127)
        bytes.concat([length].pack("Q>").bytes)
      end

      mask = SecureRandom.random_bytes(4)
      masked_payload = payload.bytes.each_with_index.map { |byte, index| (byte ^ mask.getbyte(index % 4)).chr }.join
      socket.write(bytes.pack("C*") + mask + masked_payload)
    end

    def self.read_exact(socket, length, deadline)
      buffer = +"".b
      while buffer.bytesize < length
        buffer << read_available(socket, deadline, max_length: length - buffer.bytesize)
      end
      buffer
    end

    def self.read_available(socket, deadline, max_length: 4096)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Timeout::Error if remaining <= 0

      ready = IO.select([socket], nil, nil, remaining)
      raise Timeout::Error if ready.blank?

      socket.readpartial(max_length)
    end

    def self.valid_heart_rate?(value)
      value.to_i.positive? && value.to_i < 260
    end

    def self.parse_json(body)
      JSON.parse(body.to_s.presence || "{}")
    rescue JSON::ParserError
      {}
    end

    def self.unauthorized_message(error)
      status = error.respond_to?(:status) ? error.status : nil
      detail = status.present? ? " (HTTP #{status})" : ""
      "HypeRate rejected the API key or device ID#{detail}. Check the Heartrate HypeRate settings and the user's HypeRate device ID."
    end

    def self.safe_body(body)
      body.to_s.gsub(SiteSetting.live_metrics_hyperate_api_key.to_s, "[filtered]").truncate(500)
    end
  end
end
