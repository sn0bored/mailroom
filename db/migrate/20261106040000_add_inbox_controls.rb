class AddInboxControls < ActiveRecord::Migration[8.0]
  def change
    add_column :domains, :forward_mode, :string, null: false, default: "all"
    add_column :domains, :forward_addresses, :json
    add_column :messages, :blocked, :boolean, null: false, default: false

    create_table :blocked_senders do |t|
      t.string :pattern, null: false
      t.string :note
      t.datetime :created_at, null: false
      t.index :pattern, unique: true
    end
  end
end
