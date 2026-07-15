# frozen_string_literal: true

RSpec.describe LiveMetrics::RequestRateLimiter do
  fab!(:user)

  it "uses a dedicated limit that leaves normal directory polling headroom" do
    limiter = mock
    limiter.expects(:performed!).returns(true)
    RateLimiter
      .expects(:new)
      .with(
        user,
        "live_metrics_directory",
        180,
        1.minute,
        error_code: "live_metrics_directory_limit",
        apply_limit_to_staff: true,
      )
      .returns(limiter)

    described_class.perform!(:directory, user: user, request: stub(remote_ip: "192.0.2.10"))
  end

  it "isolates anonymous limits by a non-reversible IP fingerprint" do
    limiter = mock
    limiter.expects(:performed!).returns(true)
    identity = Digest::SHA256.hexdigest("192.0.2.10").first(16)
    RateLimiter
      .expects(:new)
      .with(
        nil,
        "live_metrics_badge_status_#{identity}",
        120,
        1.minute,
        error_code: "live_metrics_badge_status_limit",
        apply_limit_to_staff: true,
      )
      .returns(limiter)

    described_class.perform!(:badge_status, user: nil, request: stub(remote_ip: "192.0.2.10"))
  end
end
