# frozen_string_literal: true

RSpec.describe LiveMetrics::ProviderAccount do
  fab!(:owner) { Fabricate(:user) }
  fab!(:viewer) { Fabricate(:user) }

  it "accepts specific-users visibility and bounded audience arrays" do
    account = described_class.create!(
      user: owner,
      provider: described_class::PROVIDER_HYPERATE,
      provider_uid: "audience-test-device",
      visibility: "specific_users",
      specific_user_ids: [viewer.id],
      blocked_user_ids: [],
    )

    expect(account.visibility).to eq("specific_users")
    expect(account.specific_user_ids).to eq([viewer.id])
    expect(described_class::MAX_AUDIENCE_USERS).to eq(100)
  end
end
