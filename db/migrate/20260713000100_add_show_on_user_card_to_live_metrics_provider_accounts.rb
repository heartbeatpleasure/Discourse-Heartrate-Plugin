# frozen_string_literal: true

class AddShowOnUserCardToLiveMetricsProviderAccounts < ActiveRecord::Migration[7.0]
  def change
    add_column :live_metrics_provider_accounts, :show_on_user_card, :boolean, null: false, default: false
  end
end
