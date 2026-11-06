class CreateOutboundMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :outbound_messages do |t|
      t.string :kind, null: false, default: "api"
      t.string :status, null: false, default: "draft"
      t.references :api_key, null: true, foreign_key: true
      t.references :user, null: true, foreign_key: true
      t.references :source_message, null: true, foreign_key: { to_table: :messages }
      t.string :from_address, null: false
      t.json :to_addresses, null: false
      t.json :cc_addresses, null: false
      t.json :bcc_addresses, null: false
      t.string :reply_to
      t.string :subject
      t.text :text_body
      t.text :html_body
      t.string :in_reply_to
      t.text :references_header
      t.string :idempotency_key
      t.string :postmark_message_id
      t.string :error
      t.datetime :sent_at
      t.timestamps
    end
    add_index :outbound_messages, [ :api_key_id, :idempotency_key ], unique: true, where: "idempotency_key IS NOT NULL"
    add_index :outbound_messages, :status
    add_index :outbound_messages, :kind
  end
end
