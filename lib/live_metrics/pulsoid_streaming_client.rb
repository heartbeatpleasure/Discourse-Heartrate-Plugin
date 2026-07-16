# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "json"
require "openssl"
require "securerandom"
require "socket"
require "timeout"
require "uri"

module ::LiveMetrics
  class PulsoidStreamingClient
    USER_AGENT = "Discourse Heartrate Pulsoid Streaming/0.1"
    MAX_HTTP_HEADER_BYTES = 32_768
    MAX_ERROR_BODY_BYTES = 65_536
    MAX_MESSAGE_BYTES = 1_048_576
    MAX_ACCESS_TOKEN_BYTES = 4096
    WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    CONNECT_TIMEOUT_SECONDS = 10
    PING_AFTER_IDLE_SECONDS = 20
    PONG_GRACE_SECONDS = 10
    DEFAULT_TRANSPORT_TIMEOUT_SECONDS = 45
    MIN_TRANSPORT_TIMEOUT_SECONDS = 15
    MAX_TRANSPORT_TIMEOUT_SECONDS = 120
    MIN_MEASURED_AT_MS = 946_684_800_000 # 2000-01-01T00:00:00Z
    MAX_FUTURE_SKEW_MS = 5.minutes.to_i * 1000

    class Error < StandardError
      attr_reader :status, :classification, :provider_code

      def initialize(message, status: nil, classification: :protocol_error, provider_code: nil)
        super(message)
        @status = status
        @classification = classification.to_sym
        @provider_code = provider_code.to_s.presence
      end
    end

    class ProtocolError < Error; end
    class StreamClosed < Error; end
    class StreamStalled < Error; end
    class ProviderError < Error; end

    # Preserves WebSocket bytes that arrive in the same packet as the HTTP 101
    # response and exposes OpenSSL's pending decrypted bytes before IO.select.
    class BufferedSocket
      def initialize(socket, initial_bytes)
        @socket = socket
        @buffer = initial_bytes.to_s.b
      end

      def to_io
        @socket
      end

      def readable_without_select?
        !@buffer.empty? || pending.positive?
      end

      def pending
        @buffer.bytesize + underlying_pending
      end

      def readpartial(max_length)
        return @buffer.slice!(0, max_length) unless @buffer.empty?

        @socket.readpartial(max_length)
      end

      def write(*args)
        @socket.write(*args)
      end

      def close
        @socket.close
      end

      private

      def underlying_pending
        return 0 unless @socket.respond_to?(:pending)

        @socket.pending.to_i
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        0
      end
    end

    class << self
      def configured?
        return false unless SiteSetting.live_metrics_pulsoid_enabled

        uri =
          ::LiveMetrics::ProviderTransport.pulsoid_wss_uri!(
            SiteSetting.live_metrics_pulsoid_ws_url,
          )
        reject_sensitive_query!(uri)
        true
      rescue ::LiveMetrics::ProviderTransport::InvalidUrl, ProtocolError, URI::InvalidURIError
        false
      rescue => e
        ::LiveMetrics::SafeLog.warn("pulsoid_stream_configuration_check_failed", error: e)
        false
      end

      def stream(
        access_token,
        stop_if:,
        on_reading:,
        on_connected: nil,
        on_frame: nil,
        on_ping: nil,
        on_socket: nil
      )
        raise ProtocolError.new("Pulsoid streaming is not configured.", classification: :configuration_error) unless configured?

        token = validated_access_token!(access_token)
        uri = ::LiveMetrics::ProviderTransport.pulsoid_wss_uri!(SiteSetting.live_metrics_pulsoid_ws_url)
        reject_sensitive_query!(uri)

        socket = open_socket(uri, token)
        on_socket&.call(socket)
        on_connected&.call

        timeout = transport_timeout_seconds
        ping_after = [PING_AFTER_IDLE_SECONDS, [timeout - PONG_GRACE_SECONDS, 5].max].min
        last_frame_at = monotonic_now
        ping_sent_at = nil

        until stop_if.call
          now = monotonic_now
          hard_deadline = last_frame_at + timeout
          ping_deadline = last_frame_at + ping_after
          pong_deadline = ping_sent_at.present? ? [ping_sent_at + PONG_GRACE_SECONDS, hard_deadline].min : nil

          if now >= hard_deadline || (pong_deadline.present? && now >= pong_deadline)
            raise StreamStalled.new(
              "Pulsoid WebSocket transport stopped responding.",
              classification: :transport_stalled,
            )
          end

          if ping_sent_at.blank? && now >= ping_deadline
            send_frame(socket, opcode: 0x9, payload: SecureRandom.random_bytes(8))
            ping_sent_at = now
            on_ping&.call
          end

          deadlines = [hard_deadline]
          deadlines << (ping_sent_at.present? ? pong_deadline : ping_deadline)
          read_deadline = deadlines.compact.min

          begin
            message =
              read_message(
                socket,
                read_deadline,
                on_frame: lambda do
                  last_frame_at = monotonic_now
                  ping_sent_at = nil
                  on_frame&.call
                end,
              )
          rescue Timeout::Error
            next
          end

          next if message.blank?

          payload = normalize_message(message)
          on_reading.call(payload) if payload.present?
        end

        true
      ensure
        begin
          socket&.close
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        end
        on_socket&.call(nil)
      end

      def normalize_message(message)
        parsed = JSON.parse(message.to_s)
        return nil unless parsed.is_a?(Hash)

        measured_at_ms = strict_positive_integer(parsed["measured_at"])
        heart_rate = strict_positive_integer(parsed.dig("data", "heart_rate"))
        return nil unless valid_measured_at_ms?(measured_at_ms)
        return nil unless heart_rate.present? && heart_rate < 260

        measured_at = Time.zone.at(measured_at_ms / 1000.0)
        age_seconds = [Time.zone.now.to_i - measured_at.to_i, 0].max

        {
          status: "live",
          heart_rate: heart_rate,
          measured_at: measured_at.iso8601,
          measured_at_ms: measured_at_ms,
          age_seconds: age_seconds,
        }
      rescue JSON::ParserError, TypeError, ArgumentError
        nil
      end

      def open_socket(uri, access_token)
        uri = ::LiveMetrics::ProviderTransport.pulsoid_wss_uri!(uri.to_s)
        reject_sensitive_query!(uri)
        token = validated_access_token!(access_token)
        tcp =
          Timeout.timeout(CONNECT_TIMEOUT_SECONDS) do
            Socket.tcp(uri.host, uri.port, connect_timeout: CONNECT_TIMEOUT_SECONDS)
          end

        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        context.verify_hostname = true if context.respond_to?(:verify_hostname=)
        socket = OpenSSL::SSL::SSLSocket.new(tcp, context)
        socket.hostname = uri.host if socket.respond_to?(:hostname=)
        socket.sync_close = true
        Timeout.timeout(CONNECT_TIMEOUT_SECONDS) { socket.connect }

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
          "Authorization: Bearer #{token}",
          "User-Agent: #{USER_AGENT}",
          "",
          "",
        ].join("\r\n")

        socket.write(request)
        response, remaining_bytes = read_http_response(socket)
        status = response[/\AHTTP\/\d\.\d\s+(\d+)/, 1].to_i

        unless status == 101
          body = read_error_body(socket, response, remaining_bytes)
          provider_error = ::LiveMetrics::PulsoidClient.error_for_response(status: status, body: body)
          raise ProviderError.new(
            "Pulsoid rejected the WebSocket connection.",
            status: status,
            classification: provider_error.classification,
            provider_code: provider_error.provider_code,
          )
        end

        verify_websocket_handshake!(response, key)
        remaining_bytes.present? ? BufferedSocket.new(socket, remaining_bytes) : socket
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

      def read_http_response(socket)
        buffer = +"".b
        deadline = monotonic_now + CONNECT_TIMEOUT_SECONDS

        until buffer.include?("\r\n\r\n")
          chunk = read_available(socket, deadline)
          break if chunk.blank?
          buffer << chunk
          if !buffer.include?("\r\n\r\n") && buffer.bytesize > MAX_HTTP_HEADER_BYTES
            raise ProtocolError.new(
              "Pulsoid WebSocket response headers exceeded the safe size limit.",
              classification: :protocol_error,
            )
          end
        end

        header_end = buffer.index("\r\n\r\n")
        if header_end.blank?
          raise ProtocolError.new(
            "Pulsoid WebSocket response headers were incomplete.",
            classification: :protocol_error,
          )
        end

        header_length = header_end + 4
        if header_length > MAX_HTTP_HEADER_BYTES
          raise ProtocolError.new(
            "Pulsoid WebSocket response headers exceeded the safe size limit.",
            classification: :protocol_error,
          )
        end
        [buffer.byteslice(0, header_length), buffer.byteslice(header_length..-1).to_s.b]
      end

      def verify_websocket_handshake!(response, key)
        status = response.to_s[/\AHTTP\/\d\.\d\s+(\d+)/, 1].to_i
        unless status == 101
          raise ProtocolError.new(
            "Pulsoid WebSocket upgrade status was invalid.",
            classification: :protocol_error,
          )
        end

        headers = websocket_response_headers(response)
        expected_accept = Base64.strict_encode64(Digest::SHA1.digest("#{key}#{WEBSOCKET_GUID}"))
        actual_accept = headers["sec-websocket-accept"].to_s
        upgrade = headers["upgrade"].to_s.downcase
        connection_tokens = headers["connection"].to_s.downcase.split(",").map(&:strip)

        unless upgrade == "websocket" && connection_tokens.include?("upgrade")
          raise ProtocolError.new(
            "Pulsoid WebSocket upgrade headers were invalid.",
            classification: :protocol_error,
          )
        end

        unless actual_accept.bytesize == expected_accept.bytesize &&
            ActiveSupport::SecurityUtils.secure_compare(actual_accept, expected_accept)
          raise ProtocolError.new(
            "Pulsoid WebSocket accept header was invalid.",
            classification: :protocol_error,
          )
        end
      end

      def websocket_response_headers(response)
        response.to_s.split("\r\n").drop(1).each_with_object({}) do |line, headers|
          name, value = line.split(":", 2)
          next if name.blank? || value.blank?

          headers[name.downcase] = value.strip
        end
      end

      def read_message(socket, deadline, on_frame: nil)
        fragmented_payload = nil

        loop do
          frame = read_frame(socket, deadline)
          on_frame&.call
          opcode = frame[:opcode]
          payload = frame[:payload]

          case opcode
          when 0x0
            raise_protocol!("Unexpected continuation frame.") if fragmented_payload.nil?

            fragmented_payload << payload
            ensure_message_size!(fragmented_payload.bytesize)
            next unless frame[:fin]

            message = fragmented_payload
            fragmented_payload = nil
            return valid_utf8_text!(message)
          when 0x1
            raise_protocol!("A new data frame arrived before fragmentation completed.") if !fragmented_payload.nil?

            return valid_utf8_text!(payload) if frame[:fin]

            fragmented_payload = payload.dup
            ensure_message_size!(fragmented_payload.bytesize)
          when 0x2
            raise_protocol!("Binary WebSocket frames are not supported.")
          when 0x8
            validate_close_payload!(payload)
            begin
              send_frame(socket, opcode: 0x8, payload: payload)
            rescue
              nil
            end
            raise StreamClosed.new(
              "Pulsoid closed the WebSocket stream.",
              classification: :stream_ended,
            )
          when 0x9
            send_frame(socket, opcode: 0xA, payload: payload)
            next
          when 0xA
            next
          else
            raise_protocol!("Unsupported WebSocket opcode.")
          end
        end
      rescue Timeout::Error
        raise if fragmented_payload.nil?

        raise StreamStalled.new(
          "Pulsoid WebSocket fragmented message was not completed in time.",
          classification: :transport_stalled,
        )
      end

      def read_frame(socket, deadline)
        header = read_exact(socket, 2, deadline)
        first = header.getbyte(0)
        second = header.getbyte(1)
        fin = (first & 0x80) != 0
        rsv = first & 0x70
        opcode = first & 0x0f
        masked = (second & 0x80) != 0
        length = second & 0x7f

        raise_protocol!("Unsupported compressed WebSocket frame.") if rsv != 0
        raise_protocol!("Server WebSocket frames must not be masked.") if masked

        length = read_exact(socket, 2, deadline).unpack1("n") if length == 126
        length = read_exact(socket, 8, deadline).unpack1("Q>") if length == 127
        ensure_message_size!(length)

        if control_opcode?(opcode)
          raise_protocol!("Fragmented control frame.") unless fin
          raise_protocol!("Oversized control frame.") if length > 125
        end

        payload = length.positive? ? read_exact(socket, length, deadline) : +"".b
        { fin: fin, opcode: opcode, payload: payload }
      end

      def send_frame(socket, opcode:, payload: "")
        payload = payload.to_s.b
        raise_protocol!("Client control frame is too large.") if control_opcode?(opcode) && payload.bytesize > 125
        ensure_message_size!(payload.bytesize)

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
        masked_payload =
          payload.bytes.each_with_index.map { |byte, index| (byte ^ mask.getbyte(index % 4)).chr }.join
        socket.write(bytes.pack("C*") + mask + masked_payload)
      end

      def read_exact(socket, length, deadline)
        buffer = +"".b
        while buffer.bytesize < length
          buffer << read_available(socket, deadline, max_length: length - buffer.bytesize)
        end
        buffer
      end

      def read_available(socket, deadline, max_length: 4096)
        unless readable_without_select?(socket)
          remaining = deadline - monotonic_now
          raise Timeout::Error if remaining <= 0

          io = socket.respond_to?(:to_io) ? socket.to_io : socket
          ready = IO.select([io], nil, nil, remaining)
          raise Timeout::Error if ready.blank?
        end

        socket.readpartial(max_length)
      end

      def readable_without_select?(socket)
        return true if socket.respond_to?(:readable_without_select?) && socket.readable_without_select?

        socket.respond_to?(:pending) && socket.pending.to_i.positive?
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        false
      end

      def transport_timeout_seconds
        configured = SiteSetting.live_metrics_pulsoid_stream_transport_timeout_seconds.to_i
        configured = DEFAULT_TRANSPORT_TIMEOUT_SECONDS if configured <= 0
        configured.clamp(MIN_TRANSPORT_TIMEOUT_SECONDS, MAX_TRANSPORT_TIMEOUT_SECONDS)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      private

      def read_error_body(socket, response, initial_bytes)
        headers = websocket_response_headers(response)
        content_length = headers["content-length"].to_i
        return initial_bytes.to_s.byteslice(0, MAX_ERROR_BODY_BYTES).to_s if content_length <= 0

        target_length = [content_length, MAX_ERROR_BODY_BYTES].min
        body = initial_bytes.to_s.b.byteslice(0, target_length).to_s.b
        deadline = monotonic_now + 2
        while body.bytesize < target_length
          body << read_available(socket, deadline, max_length: target_length - body.bytesize)
        end
        body
      rescue Timeout::Error, EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
        initial_bytes.to_s.byteslice(0, MAX_ERROR_BODY_BYTES).to_s
      end

      def validated_access_token!(value)
        token = value.to_s
        if token.blank? || token.bytesize > MAX_ACCESS_TOKEN_BYTES || !token.ascii_only? ||
             token.match?(/[[:space:]]/)
          raise ProtocolError.new(
            "Pulsoid access token is invalid.",
            classification: :configuration_error,
          )
        end

        token
      end

      def reject_sensitive_query!(uri)
        pairs = URI.decode_www_form(uri.query.to_s)
        sensitive = pairs.any? { |name, _| %w[access_token token authorization].include?(name.to_s.downcase) }
        return unless sensitive

        raise ProtocolError.new(
          "Pulsoid WebSocket credentials must not be placed in the URL.",
          classification: :configuration_error,
        )
      rescue ArgumentError
        raise ProtocolError.new(
          "Pulsoid WebSocket query parameters are invalid.",
          classification: :configuration_error,
        )
      end

      def valid_measured_at_ms?(value)
        return false if value.blank? || value < MIN_MEASURED_AT_MS

        value <= ((Time.zone.now.to_f * 1000).to_i + MAX_FUTURE_SKEW_MS)
      end

      def strict_positive_integer(value)
        return value if value.is_a?(Integer) && value.positive?

        nil
      end

      def ensure_message_size!(size)
        return if size.to_i <= MAX_MESSAGE_BYTES

        raise ProtocolError.new(
          "Pulsoid WebSocket message exceeded the safe size limit.",
          classification: :protocol_error,
        )
      end

      def valid_utf8_text!(payload)
        text = payload.dup.force_encoding(Encoding::UTF_8)
        raise_protocol!("Invalid UTF-8 text frame.") unless text.valid_encoding?

        text
      end

      def validate_close_payload!(payload)
        raise_protocol!("Invalid WebSocket close payload.") if payload.bytesize == 1
        return if payload.bytesize < 2

        code = payload.byteslice(0, 2).unpack1("n")
        valid = code.between?(1000, 1014) && ![1004, 1005, 1006].include?(code)
        valid ||= code.between?(3000, 4999)
        raise_protocol!("Invalid WebSocket close code.") unless valid

        valid_utf8_text!(payload.byteslice(2..-1).to_s.b) if payload.bytesize > 2
      end

      def control_opcode?(opcode)
        [0x8, 0x9, 0xA].include?(opcode)
      end

      def raise_protocol!(message)
        raise ProtocolError.new(message, classification: :protocol_error)
      end
    end
  end
end
