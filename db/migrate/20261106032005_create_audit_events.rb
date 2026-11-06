class CreateAuditEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_events do |t|
      t.string :actor_type
      t.integer :actor_id
      t.string :action, null: false
      t.string :target_type
      t.integer :target_id
      t.string :outcome, null: false, default: "ok"
      t.string :error_class
      t.string :ip
      t.integer :duration_ms
      t.datetime :created_at, null: false
    end
    add_index :audit_events, :created_at
    add_index :audit_events, [ :actor_type, :actor_id ]
  end
end
