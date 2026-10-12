# frozen_string_literal: true

class EnsureProfileAndNotificationColumns < ActiveRecord::Migration[8.1]
  def up
    # Accounts
    add_column :accounts, :show_media, :boolean, null: false, default: true unless column_exists?(:accounts, :show_media)
    add_column :accounts, :show_media_replies, :boolean, null: false, default: true unless column_exists?(:accounts, :show_media_replies)
    add_column :accounts, :show_featured, :boolean, null: false, default: true unless column_exists?(:accounts, :show_featured)
    add_column :accounts, :avatar_description, :string, null: false, default: '' unless column_exists?(:accounts, :avatar_description)
    add_column :accounts, :header_description, :string, null: false, default: '' unless column_exists?(:accounts, :header_description)

    # Notification policies
    add_column :notification_policies, :for_bots, :integer, null: false, default: 0 unless column_exists?(:notification_policies, :for_bots)
  end

  def down
    # Intentionally left blank: this migration only backfills columns that
    # should already exist. Removing them could drop pre-existing data.
  end
end
