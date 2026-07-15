# frozen_string_literal: true

RSpec.describe LiveMetrics::SafeLog do
  it "logs bounded operation codes and exception classes without exception messages" do
    error = StandardError.new("access_token=must-never-appear")

    Rails.logger.expects(:warn).with do |message|
      expect(message).to include("[live_metrics] provider_request_failed")
      expect(message).to include("error_class=StandardError")
      expect(message).to include("provider=pulsoid")
      expect(message).not_to include("must-never-appear")
      true
    end

    described_class.warn("provider request failed", error: error, provider: "pulsoid")
  end
end
