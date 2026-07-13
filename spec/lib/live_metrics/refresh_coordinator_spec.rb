# frozen_string_literal: true

RSpec.describe LiveMetrics::RefreshCoordinator do
  fab!(:user)
  fab!(:account) do
    LiveMetrics::ProviderAccount.create!(
      user: user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "test-device",
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
  end

  before do
    Jobs.stubs(:enqueue)
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_hyperate_enabled = true
    SiteSetting.live_metrics_hyperate_api_key = "test-key"
    SiteSetting.live_metrics_hyperate_streaming_enabled = false
    SiteSetting.live_metrics_async_current_readings_enabled = true
    described_class.stop(account)
  end

  after { described_class.stop(account) }

  it "starts only one generation for repeated recovery calls" do
    described_class.expects(:enqueue_refresh).once.returns(true)

    first = described_class.start(account)
    second = described_class.start(account)

    expect(first).to be_present
    expect(second).to eq(first)
  end

  it "does not leave a loop token when the initial job cannot be enqueued" do
    described_class.expects(:enqueue_refresh).once.returns(false)

    expect(described_class.start(account)).to be_nil
    expect(described_class.current_generation(account)).to be_nil
  end

  it "invalidates the prior generation on restart" do
    first = described_class.start(account)
    second = described_class.restart(account)

    expect(second).to be_present
    expect(second).not_to eq(first)
    expect(described_class.generation_current?(account, first)).to eq(false)
    expect(described_class.generation_current?(account, second)).to eq(true)
  end

  it "removes current state when the loop stops" do
    described_class.start(account)
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 80,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )

    described_class.stop(account)

    expect(LiveMetrics::CurrentStateStore.read(account)).to be_nil
    expect(described_class.current_generation(account)).to be_nil
  end

  it "does not write state after a generation has been invalidated" do
    generation = described_class.start(account)
    described_class.stop(account)

    state = described_class.write_state_if_current(
      account,
      {
        status: "live",
        heart_rate: 90,
        measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
      },
      generation,
    )

    expect(state).to be_nil
    expect(LiveMetrics::CurrentStateStore.read(account)).to be_nil
  end

  it "preserves an in-flight fetch lock while restarting the same account" do
    described_class.start(account)
    lock_token = described_class.acquire_fetch_lock(account)

    described_class.restart(account)

    expect(lock_token).to be_present
    expect(described_class.acquire_fetch_lock(account)).to be_nil
  ensure
    described_class.release_fetch_lock(account, lock_token) if lock_token
  end
  it "moves HypeRate out of Sidekiq while streaming mode is enabled" do
    SiteSetting.live_metrics_hyperate_streaming_enabled = true
    described_class.expects(:enqueue_refresh).never

    result = described_class.start(account)

    expect(result).to be_nil
    expect(described_class.streaming_eligible?(account)).to eq(true)
    expect(described_class.eligible?(account)).to eq(false)
    expect(described_class.current_generation(account)).to be_nil
  end

  it "preserves a streaming reading during routine recovery sync" do
    SiteSetting.live_metrics_hyperate_streaming_enabled = true
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: 83,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )

    described_class.sync_user(user.id)

    expect(LiveMetrics::CurrentStateStore.read(account)[:heart_rate]).to eq(83)
  end

  it "keeps Pulsoid on the existing background refresh path" do
    pulsoid_user = Fabricate(:user)
    pulsoid = LiveMetrics::ProviderAccount.create!(
      user: pulsoid_user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_PULSOID,
      visibility: "private",
      active: true,
      access_token_cipher: "encrypted-access",
      refresh_token_cipher: "encrypted-refresh",
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
    SiteSetting.live_metrics_pulsoid_enabled = true
    SiteSetting.live_metrics_hyperate_streaming_enabled = true

    expect(described_class.streaming_eligible?(pulsoid)).to eq(false)
    expect(described_class.eligible?(pulsoid)).to eq(true)
  ensure
    described_class.stop(pulsoid) if pulsoid
  end

end
