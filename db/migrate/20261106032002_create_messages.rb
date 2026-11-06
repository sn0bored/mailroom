class CreateMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :messages do |t|
      t.references :inbound_email, null: false, index: { unique: true }
      t.references :domain, null: true, foreign_key: true
      t.string :to_address
      t.json :matched_addresses, null: false
      t.string :routed_via
      t.json :routing_trace, null: false
      t.string :rfc822_message_id
      t.string :in_reply_to
      t.text :references_header
      t.string :from_address
      t.string :from_name
      t.string :reply_to
      t.string :subject
      t.datetime :sent_at
      t.datetime :received_at, null: false
      t.text :body_text
      t.boolean :has_html, null: false, default: false
      t.string :snippet
      t.float :spam_score
      t.boolean :list_mail, null: false, default: false
      t.integer :size_bytes
      t.datetime :read_at
      t.datetime :archived_at
      t.string :forward_status
      t.string :parse_error
      t.timestamps
    end
    add_foreign_key :messages, :action_mailbox_inbound_emails, column: :inbound_email_id
    add_index :messages, [ :domain_id, :received_at ]
    add_index :messages, :received_at
    add_index :messages, :read_at
    add_index :messages, :rfc822_message_id
  end
end
