# frozen_string_literal: true

class CreateLiveMetricsProviderAccounts < ActiveRecord::Migration[7.0]
  def change
    create_table :live_metrics_provider_accounts do |t|
      t.integer :user_id, null: false
      t.string :provider, null: false
      t.string :provider_uid
      t.string :display_name
      t.text :profile_data
      t.text :access_token_cipher
      t.text :refresh_token_cipher
      t.datetime :token_expires_at
      t.text :scopes
      t.string :visibility, null: false, default: "private"
      t.boolean :show_on_profile, null: false, default: false
      t.boolean :show_in_directory, null: false, default: false
      t.datetime :last_profile_synced_at
      t.string :last_error
      t.timestamps null: false
    end

    add_index :live_metrics_provider_accounts, [:user_id, :provider], unique: true, name: "idx_live_metrics_accounts_user_provider"
    add_index :live_metrics_provider_accounts, [:provider, :show_in_directory], name: "idx_live_metrics_accounts_directory"
    add_index :live_metrics_provider_accounts, :provider_uid, name: "idx_live_metrics_accounts_provider_uid"
  end
end
