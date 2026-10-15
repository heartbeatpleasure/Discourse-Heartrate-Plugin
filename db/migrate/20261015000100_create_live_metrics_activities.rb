# frozen_string_literal: true

class CreateLiveMetricsActivities < ActiveRecord::Migration[7.0]
  def change
    create_table :live_metrics_activities do |t|
      t.integer :user_id, null: false
      t.string :activity_name, null: false, limit: 80
      t.string :details, limit: 80
      t.boolean :is_custom, null: false, default: false
      t.integer :duration_minutes
      t.datetime :expires_at
      t.timestamps
    end
    add_index :live_metrics_activities, :user_id, unique: true
    add_foreign_key :live_metrics_activities, :users, column: :user_id, on_delete: :cascade
  end
end
