class CreateDomains < ActiveRecord::Migration[8.0]
  def change
    create_table :domains do |t|
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.string :forward_copy_to
      t.float :forward_copy_max_spam, null: false, default: 5.0
      t.boolean :send_enabled, null: false, default: false
      t.string :probe_token
      t.datetime :probe_received_at
      t.datetime :last_received_at
      t.text :notes
      t.timestamps
    end
    add_index :domains, :name, unique: true
  end
end
