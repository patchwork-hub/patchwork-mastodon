class RemoveIsBannedFromStatuses < ActiveRecord::Migration[8.0]
  def change
    if column_exists?(:statuses, :is_banned)
      safety_assured {
        remove_column :statuses, :is_banned
      }
    end

    if column_exists?(:accounts, :is_banned)
      safety_assured {
        remove_column :accounts, :is_banned
      }
    end
  end
end
