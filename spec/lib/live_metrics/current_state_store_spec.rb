# frozen_string_literal: true

RSpec.describe LiveMetrics::CurrentStateStore do
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
    SiteSetting.live_metrics_live_threshold_seconds = 12
    SiteSetting.live_metrics_stale_threshold_seconds = 60
    described_class.delete(account)
  end

  after { described_class.delete(account) }

  it "stores only the latest reading and applies a hard expiry" do
    now_ms = (Time.zone.now.to_f * 1000).to_i

    described_class.write(
      account,
      status: "live",
      heart_rate: 80,
      measured_at_ms: now_ms,
    )
    described_class.write(
      account,
      status: "live",
      heart_rate: 86,
      measured_at_ms: now_ms,
    )

    state = described_class.read(account)
    expect(state[:heart_rate]).to eq(86)
    expect(state[:status]).to eq("live")
    expect(Discourse.redis.ttl(described_class.key(account))).to be_between(1, 75)
  end

  it "recalculates freshness when reading" do
    measured_at_ms = ((Time.zone.now - 20.seconds).to_f * 1000).to_i

    described_class.write(
      account,
      status: "live",
      heart_rate: 82,
      measured_at_ms: measured_at_ms,
    )

    expect(described_class.read(account)[:status]).to eq("delayed")
  end

  it "expires an older reading based on measured age instead of write time" do
    measured_at_ms = ((Time.zone.now - 70.seconds).to_f * 1000).to_i

    described_class.write(
      account,
      status: "stale",
      heart_rate: 82,
      measured_at_ms: measured_at_ms,
    )

    expect(Discourse.redis.ttl(described_class.key(account))).to be_between(1, 5)
  end

  it "does not retain a reading older than the hard retention window" do
    measured_at_ms = ((Time.zone.now - 90.seconds).to_f * 1000).to_i

    described_class.write(
      account,
      status: "stale",
      heart_rate: 82,
      measured_at_ms: measured_at_ms,
    )

    state = described_class.read(account)
    expect(state[:heart_rate]).to be_nil
    expect(state[:status]).to eq("no_data")
  end

  it "writes only while the supplied generation guard is current" do
    guard_key = "live_metrics:test:guard:#{account.id}"
    Discourse.redis.set(guard_key, "current", ex: 30)
    now_ms = (Time.zone.now.to_f * 1000).to_i

    expect(
      described_class.write_if(
        account,
        { status: "live", heart_rate: 81, measured_at_ms: now_ms },
        guard_key: guard_key,
        guard_value: "old",
      ),
    ).to be_nil
    expect(described_class.read(account)).to be_nil

    state = described_class.write_if(
      account,
      { status: "live", heart_rate: 83, measured_at_ms: now_ms },
      guard_key: guard_key,
      guard_value: "current",
    )
    expect(state[:heart_rate]).to eq(83)
  ensure
    Discourse.redis.del(guard_key) if guard_key
  end


  it "never returns a reading beyond the hard retention window" do
    now_ms = (Time.zone.now.to_f * 1000).to_i
    payload = {
      v: LiveMetrics::CurrentStateStore::VERSION,
      provider: account.provider,
      status: "live",
      heart_rate: 89,
      measured_at_ms: now_ms - ((described_class.ttl_seconds + 5) * 1000),
      received_at_ms: now_ms,
      error_code: nil,
    }
    Discourse.redis.set(
      described_class.key(account),
      JSON.generate(payload),
      ex: 30,
    )

    state = described_class.read(account)
    expect(state[:heart_rate]).to be_nil
    expect(state[:status]).to eq("no_data")
  end

  it "fails closed for malformed Redis data" do
    Discourse.redis.set(described_class.key(account), "not-json", ex: 30)

    expect(described_class.read(account)).to be_nil
  end
  it "reads multiple account states with one batched lookup" do
    second_user = Fabricate(:user)
    second_account = LiveMetrics::ProviderAccount.create!(
      user: second_user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "second-device",
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
    now_ms = (Time.zone.now.to_f * 1000).to_i

    described_class.write(account, status: "live", heart_rate: 80, measured_at_ms: now_ms)
    described_class.write(
      second_account,
      status: "live",
      heart_rate: 91,
      measured_at_ms: now_ms,
    )

    states = described_class.read_many([account, second_account])
    expect(states.dig(account.id, :heart_rate)).to eq(80)
    expect(states.dig(second_account.id, :heart_rate)).to eq(91)
  ensure
    described_class.delete(second_account) if second_account
    second_account&.destroy!
  end
end
