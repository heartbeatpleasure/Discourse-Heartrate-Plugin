# frozen_string_literal: true

require "base64"
require "cgi"
require "json"
require "openssl"
require "securerandom"
require "socket"
require "timeout"
require "time"
require "uri"

module ::LiveMetrics
  class HypeRateClient
    USER_AGENT = "Discourse Heartrate HypeRate/0.1"
    DEVICE_PATH_WS_URL = "wss://app.hyperate.io/ws/:deviceId"
    LEGACY_WS_URL = "wss://app.hyperate.io/socket/websocket"
    LEGACY_SOCKET_PATH = "/socket/websocket"
    DEVICE_SOCKET_PATH = "/ws"
    DEFAULT_ORIGIN = "https://app.hyperate.io"
    MAX_DEVICE_ID_LENGTH = 128
    MIN_READ_TIMEOUT_SECONDS = 2
    MAX_READ_TIMEOUT_SECONDS = 30
    MAX_CONNECT_TIMEOUT_SECONDS = 10
    CONNECTION_TIMEOUT_GRACE_SECONDS = 3
    HEARTBEAT_INTERVAL_SECONDS = 15
    DEFAULT_STREAM_STALL_TIMEOUT_SECONDS = 45
    JOIN_TIMEOUT_SECONDS = 10
    MAX_MESSAGE_BYTES = 1_048_576
    MIN_STREAM_STALL_TIMEOUT_SECONDS = 10
    MAX_STREAM_STALL_TIMEOUT_SECONDS = 120

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
    class StreamStalled < NoHeartRateData; end

    # Preserves WebSocket bytes that arrive in the same packet as the HTTP 101
    # response. Without this buffer, an immediate join reply or heart-rate event
    # can be consumed during the handshake and silently discarded.
    class BufferedSocket
      def initialize(socket, initial_bytes)
        @socket = socket
        @buffer = initial_bytes.to_s.b
      end

      def to_io
        @socket
      end

      # OpenSSL may already have decrypted bytes buffered internally even when
      # IO.select reports the underlying file descriptor as not readable.
      # Exposing this prevents complete WebSocket frames from waiting for a
      # later network packet before they are parsed.
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

    # Performs one uncached HypeRate WebSocket read. Background refresh jobs use
    # this method; `latest` remains as the legacy cached synchronous wrapper for
    # rollback while the async current-reading feature flag is disabled.
    def self.fetch_latest(account, persist_last_error: true)
      return { status: "unavailable", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: "HypeRate is not configured." } unless configured?

      device_id = normalize_device_id(account.provider_uid)
      return { status: "no_data", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: "Missing HypeRate device ID." } if device_id.blank?

      begin
        clear_last_error(account) if persist_last_error
        normalize_latest_response(read_latest_heart_rate(device_id))
      rescue Unauthorized => e
        persist_unauthorized(account) if persist_last_error
        { status: "unauthorized", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: unauthorized_message(e) }
      rescue NoHeartRateData => e
        clear_last_error(account) if persist_last_error
        { status: "no_data", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: e.message }
      rescue => e
        Rails.logger.warn("[live_metrics] HypeRate latest failed account_id=#{account.id} error=#{e.class}: #{e.message}")
        { status: "unavailable", heart_rate: nil, measured_at: nil, measured_at_ms: nil, error: "HypeRate data is temporarily unavailable." }
      end
    end

    def self.latest(account)
      device_id = normalize_device_id(account.provider_uid)
      cache_key = "live_metrics:hyperate:latest:v2:#{account.id}:#{device_id}:#{account.updated_at.to_i}"

      Discourse.cache.fetch(cache_key, expires_in: SiteSetting.live_metrics_api_cache_seconds.seconds) do
        fetch_latest(account)
      end
    end

    # Keeps a HypeRate WebSocket open and yields every heart-rate event until
    # stop_if returns true or the connection closes. This is used only by the
    # dedicated streaming collector; the legacy single-read methods remain for
    # rollback and for synchronous mode.
    def self.stream(
      device_id,
      stop_if:,
      on_reading:,
      on_connected: nil,
      on_heartbeat: nil,
      on_frame: nil,
      on_socket: nil
    )
      raise Error.new("HypeRate is not configured.") unless configured?

      device_id = normalize_device_id(device_id)
      raise NoHeartRateData.new("Missing HypeRate device ID.") if device_id.blank?

      last_error = nil

      websocket_uri_candidates(device_id).each do |candidate|
        begin
          return stream_from_uri(
            device_id,
            candidate,
            stop_if: stop_if,
            on_reading: on_reading,
            on_connected: on_connected,
            on_heartbeat: on_heartbeat,
            on_frame: on_frame,
            on_socket: on_socket,
          )
        rescue Unauthorized, Error => e
          last_error = e
          if fallback_allowed_for?(e)
            Rails.logger.warn(
              "[live_metrics] HypeRate streaming candidate failed endpoint=#{candidate[:name]} status=#{e.respond_to?(:status) ? e.status : nil} error=#{e.class}: #{e.message}",
            )
            next
          end

          raise
        end
      end

      raise(last_error || Error.new("No HypeRate WebSocket endpoint was available."))
    end

    def self.stream_from_uri(
      device_id,
      candidate,
      stop_if:,
      on_reading:,
      on_connected: nil,
      on_heartbeat: nil,
      on_frame: nil,
      on_socket: nil
    )
      socket = open_socket(candidate[:uri])
      on_socket&.call(socket)
      send_text_frame(socket, join_message(device_id))

      connected_at = monotonic_now
      last_frame_at = connected_at
      next_heartbeat = connected_at + HEARTBEAT_INTERVAL_SECONDS
      transport_timeout = stream_stall_timeout_seconds
      join_deadline = connected_at + JOIN_TIMEOUT_SECONDS
      joined = false

      until stop_if.call
        now = monotonic_now
        transport_deadline = last_frame_at + transport_timeout

        raise StreamStalled.new(stream_stalled_message(transport_timeout)) if now >= transport_deadline
        raise Error.new("HypeRate channel join timed out.") if !joined && now >= join_deadline

        if now >= next_heartbeat
          send_text_frame(socket, heartbeat_message)
          on_heartbeat&.call
          next_heartbeat = now + HEARTBEAT_INTERVAL_SECONDS
        end

        deadlines = [next_heartbeat, transport_deadline]
        deadlines << join_deadline unless joined
        read_deadline = deadlines.min

        begin
          message =
            read_message(
              socket,
              read_deadline,
              on_frame: lambda do
                last_frame_at = monotonic_now
                on_frame&.call
              end,
            )
        rescue Timeout::Error
          now = monotonic_now
          raise StreamStalled.new(stream_stalled_message(transport_timeout)) if now >= transport_deadline
          raise Error.new("HypeRate channel join timed out.") if !joined && now >= join_deadline

          next
        end
        next if message.blank?

        payload = parse_json(message)
        event = payload["event"].to_s

        if event == "phx_reply" && payload["ref"].to_s == "1"
          status = payload.dig("payload", "status").to_s
          if status == "error"
            reason =
              payload.dig("payload", "response", "reason").presence ||
                payload.dig("payload", "response", "message").presence ||
                "HypeRate rejected the channel join."
            raise Unauthorized.new(reason) if reason.to_s.match?(/auth|token|unauthor|forbid|reject|invalid/i)

            raise Error.new(reason.to_s)
          end

          unless joined
            joined = true
            on_connected&.call
          end
          next
        end

        next unless event == "hr_update"

        # A valid HR event proves the channel is joined even if the join reply
        # and the first update were delivered in an unexpected order.
        unless joined
          joined = true
          on_connected&.call
        end

        heart_rate = payload.dig("payload", "hr")
        next unless valid_heart_rate?(heart_rate)

        on_reading.call(normalize_latest_response(heart_rate))
      end

      true
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

      on_socket&.call(nil)
    end

    def self.clear_last_error(account)
      return if account.last_error.blank?

      updated =
        account.class
          .where(
            id: account.id,
            updated_at: account.updated_at,
            provider_uid: account.provider_uid,
          )
          .update_all(last_error: nil)
      account.last_error = nil if updated == 1
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def self.persist_unauthorized(account)
      now = Time.zone.now
      updated =
        account.class
          .where(
            id: account.id,
            updated_at: account.updated_at,
            provider_uid: account.provider_uid,
          )
          .update_all(last_error: "unauthorized", updated_at: now)
      if updated == 1
        account.last_error = "unauthorized"
        account.updated_at = now
      end
    rescue ActiveRecord::ActiveRecordError
      nil
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
      read_timeout = read_timeout_seconds
      socket = nil

      # The setting is a data-read timeout, not a combined TCP/TLS/handshake
      # timeout. Start the heart-rate deadline only after the socket is open and
      # the channel join has been sent, otherwise connection setup can consume a
      # meaningful part of HypeRate's normal ~10 second update cadence.
      total_timeout =
        connect_timeout_seconds + read_timeout + CONNECTION_TIMEOUT_GRACE_SECONDS

      Timeout.timeout(total_timeout) do
        socket = open_socket(candidate[:uri])
        send_text_frame(socket, join_message(device_id))
        deadline = monotonic_now + read_timeout

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
      tcp = Socket.tcp(uri.host, uri.port || 443, connect_timeout: connect_timeout_seconds)

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
      response, remaining_bytes = read_http_response(socket)
      status = response[/\AHTTP\/\d\.\d\s+(\d+)/, 1].to_i

      raise Unauthorized.new("HypeRate authorization failed", status: status, body: safe_body(response)) if [401, 403].include?(status)
      raise Error.new("HypeRate WebSocket handshake failed", status: status, body: safe_body(response)) unless status == 101

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

    def self.websocket_uri_candidates(device_id)
      configured_base = SiteSetting.live_metrics_hyperate_ws_url.to_s.strip
      bases = []
      bases << configured_base if configured_base.present? && configured_base != LEGACY_WS_URL
      bases << DEVICE_PATH_WS_URL
      bases << LEGACY_WS_URL

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

    def self.heartbeat_message
      {
        event: "ping",
        payload: { timestamp: (Time.now.to_f * 1000).to_i },
      }.to_json
    end

    def self.read_http_response(socket)
      buffer = +"".b
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + connect_timeout_seconds

      until buffer.include?("\r\n\r\n")
        chunk = read_available(socket, deadline)
        break if chunk.blank?
        buffer << chunk
      end

      header_end = buffer.index("\r\n\r\n")
      return [buffer, +"".b] if header_end.blank?

      header_length = header_end + 4
      [buffer.byteslice(0, header_length), buffer.byteslice(header_length..-1).to_s.b]
    end

    def self.read_message(socket, deadline, on_frame: nil)
      fragmented_opcode = nil
      fragmented_payload = +"".b

      loop do
        frame = read_frame(socket, deadline)
        on_frame&.call
        opcode = frame[:opcode]
        payload = frame[:payload]

        case opcode
        when 0x0
          next if fragmented_opcode.nil?

          fragmented_payload << payload
          ensure_message_size!(fragmented_payload.bytesize)
          next unless frame[:fin]

          complete_opcode = fragmented_opcode
          fragmented_opcode = nil
          complete_payload = fragmented_payload
          fragmented_payload = +"".b
          return complete_payload.force_encoding("UTF-8") if complete_opcode == 0x1
        when 0x1, 0x2
          if frame[:fin]
            return payload.force_encoding("UTF-8") if opcode == 0x1
          else
            fragmented_opcode = opcode
            fragmented_payload = payload.dup
            ensure_message_size!(fragmented_payload.bytesize)
          end
        when 0x8
          raise NoHeartRateData.new("HypeRate closed the WebSocket stream.")
        when 0x9
          send_frame(socket, opcode: 0xA, payload: payload)
        when 0xA
          # WebSocket pong; transport liveness is recorded by the caller.
        end
      end
    end

    def self.read_frame(socket, deadline)
      header = read_exact(socket, 2, deadline)
      first = header.getbyte(0)
      second = header.getbyte(1)
      fin = (first & 0x80) != 0
      rsv = first & 0x70
      opcode = first & 0x0f
      masked = (second & 0x80) != 0
      length = second & 0x7f

      raise Error.new("HypeRate sent an unsupported compressed WebSocket frame.") if rsv != 0

      length = read_exact(socket, 2, deadline).unpack1("n") if length == 126
      length = read_exact(socket, 8, deadline).unpack1("Q>") if length == 127
      ensure_message_size!(length)

      mask = masked ? read_exact(socket, 4, deadline).bytes : nil
      payload = length.positive? ? read_exact(socket, length, deadline) : +"".b

      if masked && mask
        payload =
          payload.bytes.each_with_index.map { |byte, index| (byte ^ mask[index % 4]).chr }.join.b
      end

      { fin: fin, opcode: opcode, payload: payload }
    end

    def self.ensure_message_size!(size)
      raise Error.new("HypeRate WebSocket message exceeded the safe size limit.") if size.to_i > MAX_MESSAGE_BYTES
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
      unless readable_without_select?(socket)
        remaining = deadline - monotonic_now
        raise Timeout::Error if remaining <= 0

        ready = IO.select([socket], nil, nil, remaining)
        raise Timeout::Error if ready.blank?
      end

      socket.readpartial(max_length)
    end

    def self.readable_without_select?(socket)
      if socket.respond_to?(:readable_without_select?) && socket.readable_without_select?
        return true
      end

      socket.respond_to?(:pending) && socket.pending.to_i.positive?
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      false
    end

    def self.monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def self.stream_stall_timeout_seconds
      configured = SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds.to_i
      configured = DEFAULT_STREAM_STALL_TIMEOUT_SECONDS if configured <= 0
      configured.clamp(MIN_STREAM_STALL_TIMEOUT_SECONDS, MAX_STREAM_STALL_TIMEOUT_SECONDS)
    end

    def self.stream_stalled_message(timeout_seconds)
      "No HypeRate WebSocket frame or heartbeat response was received for #{timeout_seconds.to_i} seconds; reconnecting the stream."
    end

    def self.read_timeout_seconds
      configured = SiteSetting.live_metrics_hyperate_read_timeout_seconds.to_i
      configured = 15 if configured <= 0
      configured.clamp(MIN_READ_TIMEOUT_SECONDS, MAX_READ_TIMEOUT_SECONDS)
    end

    def self.connect_timeout_seconds
      read_timeout_seconds.clamp(MIN_READ_TIMEOUT_SECONDS, MAX_CONNECT_TIMEOUT_SECONDS)
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
