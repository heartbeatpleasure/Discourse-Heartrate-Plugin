# frozen_string_literal: true

class AddAudienceUserIdsToLiveMetricsProviderAccounts < ActiveRecord::Migration[7.0]
  def change
    add_column :live_metrics_provider_accounts, :specific_user_ids, :integer, array: true, null: false, default: []
    add_column :live_metrics_provider_accounts, :blocked_user_ids, :integer, array: true, null: false, default: []
  end
end
