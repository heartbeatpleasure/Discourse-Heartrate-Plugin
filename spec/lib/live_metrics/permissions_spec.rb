# frozen_string_literal: true

RSpec.describe LiveMetrics::Permissions do
  fab!(:owner) { Fabricate(:user) }
  fab!(:viewer) { Fabricate(:user) }
  fab!(:account) do
    LiveMetrics::ProviderAccount.create!(
      user: owner,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "visibility-policy-device",
      visibility: "public",
      active: true,
      show_in_directory: true,
    )
  end

  before do
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_viewer_groups = ""
    SiteSetting.live_metrics_allowed_sharer_groups = ""
    SiteSetting.live_metrics_require_login_to_view_page = true
  end

  it "always keeps private as the fail-closed visibility option" do
    SiteSetting.live_metrics_allowed_visibility_options = "logged_in"

    expect(described_class.visibility_option_ids).to eq(%w[private logged_in])
  end

  it "treats a previously saved but disabled visibility as private immediately" do
    SiteSetting.live_metrics_allowed_visibility_options = "private|logged_in"

    expect(described_class.effective_visibility_id(account)).to eq("private")
    expect(described_class.can_view_account?(account, viewer)).to eq(false)
    expect(described_class.can_view_account?(account, owner)).to eq(true)
  end

  it "durably resets disallowed visibility values to private" do
    SiteSetting.live_metrics_allowed_visibility_options =
      "private|specific_users|logged_in|public|staff"
    account.update!(visibility: "public")
    described_class.stubs(:visibility_option_ids).returns(%w[private logged_in])

    expect(described_class.enforce_visibility_options!).to eq(1)
    expect(account.reload.visibility).to eq("private")
  end
end
