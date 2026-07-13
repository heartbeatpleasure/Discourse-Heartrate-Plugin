# frozen_string_literal: true

RSpec.describe LiveMetrics::HypeRateStreamingSupervisor do
  before do
    SiteSetting.live_metrics_hyperate_api_key = "test-key"
    SiteSetting.live_metrics_hyperate_ws_url = "wss://app.hyperate.io/ws/:deviceId"
    SiteSetting.live_metrics_hyperate_max_streams = 2
    SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds = 25
  end

  it "enforces the configured per-site stream limit" do
    3.times do |index|
      LiveMetrics::ProviderAccount.create!(
        user: Fabricate(:user),
        provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
        provider_uid: "device-#{index}",
        visibility: "private",
        active: true,
        show_on_profile: false,
        show_on_user_card: false,
        show_in_directory: false,
      )
    end

    desired = described_class.new.send(:desired_accounts)

    expect(desired.length).to eq(2)
    expect(desired.values).to all(include(:fingerprint))
  end

  it "uses a safety default that supports fifty concurrent streams" do
    SiteSetting.live_metrics_hyperate_max_streams = 100

    expect(described_class.new.send(:max_streams)).to eq(100)
  end

  it "restarts stream sessions when the inactivity timeout changes" do
    account = LiveMetrics::ProviderAccount.create!(
      user: Fabricate(:user),
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "device-timeout",
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )

    first = described_class.new.send(:desired_accounts).fetch(account.id).fetch(:fingerprint)
    SiteSetting.live_metrics_hyperate_stream_stall_timeout_seconds = 40
    second = described_class.new.send(:desired_accounts).fetch(account.id).fetch(:fingerprint)

    expect(second).not_to eq(first)
  end
end
