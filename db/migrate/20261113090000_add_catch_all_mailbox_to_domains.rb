class AddCatchAllMailboxToDomains < ActiveRecord::Migration[8.1]
  def change
    add_column :domains, :catch_all_mailbox, :string
  end
end
