# frozen_string_literal: true

require_dependency "demon/base"

module ::LiveMetrics
  class PulsoidStreamingDemon < ::Demon::Base
    def self.prefix
      "live-metrics-pulsoid-streaming"
    end

    def stop_timeout
      15
    end

    def after_fork
      supervisor = ::LiveMetrics::PulsoidStreamingSupervisor.new
      Signal.trap("TERM") { supervisor.request_stop }
      Signal.trap("INT") { supervisor.request_stop }
      supervisor.run
    rescue => e
      ::LiveMetrics::SafeLog.error("pulsoid_stream_demon_stopped", error: e)
      raise
    end
  end
end
