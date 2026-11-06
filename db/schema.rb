# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_06_040000) do
  create_table "action_mailbox_inbound_emails", force: :cascade do |t|
    t.integer "status", default: 0, null: false
    t.string "message_id", null: false
    t.string "message_checksum", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "message_checksum"], name: "index_action_mailbox_inbound_emails_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "api_keys", force: :cascade do |t|
    t.string "name", null: false
    t.string "token_prefix", null: false
    t.string "token_digest", null: false
    t.json "scopes", null: false
    t.json "allowed_from_domains", null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_api_keys_on_token_digest", unique: true
  end

  create_table "audit_events", force: :cascade do |t|
    t.string "actor_type"
    t.integer "actor_id"
    t.string "action", null: false
    t.string "target_type"
    t.integer "target_id"
    t.string "outcome", default: "ok", null: false
    t.string "error_class"
    t.string "ip"
    t.integer "duration_ms"
    t.datetime "created_at", null: false
    t.index ["actor_type", "actor_id"], name: "index_audit_events_on_actor_type_and_actor_id"
    t.index ["created_at"], name: "index_audit_events_on_created_at"
  end

  create_table "blocked_senders", force: :cascade do |t|
    t.string "pattern", null: false
    t.string "note"
    t.datetime "created_at", null: false
    t.index ["pattern"], name: "index_blocked_senders_on_pattern", unique: true
  end

  create_table "domains", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.string "forward_copy_to"
    t.float "forward_copy_max_spam", default: 5.0, null: false
    t.boolean "send_enabled", default: false, null: false
    t.string "probe_token"
    t.datetime "probe_received_at"
    t.datetime "last_received_at"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "forward_mode", default: "all", null: false
    t.json "forward_addresses"
    t.index ["name"], name: "index_domains_on_name", unique: true
  end

  create_table "messages", force: :cascade do |t|
    t.integer "inbound_email_id", null: false
    t.integer "domain_id"
    t.string "to_address"
    t.json "matched_addresses", null: false
    t.string "routed_via"
    t.json "routing_trace", null: false
    t.string "rfc822_message_id"
    t.string "in_reply_to"
    t.text "references_header"
    t.string "from_address"
    t.string "from_name"
    t.string "reply_to"
    t.string "subject"
    t.datetime "sent_at"
    t.datetime "received_at", null: false
    t.text "body_text"
    t.boolean "has_html", default: false, null: false
    t.string "snippet"
    t.float "spam_score"
    t.boolean "list_mail", default: false, null: false
    t.integer "size_bytes"
    t.datetime "read_at"
    t.datetime "archived_at"
    t.string "forward_status"
    t.string "parse_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "blocked", default: false, null: false
    t.index ["domain_id", "received_at"], name: "index_messages_on_domain_id_and_received_at"
    t.index ["domain_id"], name: "index_messages_on_domain_id"
    t.index ["inbound_email_id"], name: "index_messages_on_inbound_email_id", unique: true
    t.index ["read_at"], name: "index_messages_on_read_at"
    t.index ["received_at"], name: "index_messages_on_received_at"
    t.index ["rfc822_message_id"], name: "index_messages_on_rfc822_message_id"
  end

  create_table "outbound_messages", force: :cascade do |t|
    t.string "kind", default: "api", null: false
    t.string "status", default: "draft", null: false
    t.integer "api_key_id"
    t.integer "user_id"
    t.integer "source_message_id"
    t.string "from_address", null: false
    t.json "to_addresses", null: false
    t.json "cc_addresses", null: false
    t.json "bcc_addresses", null: false
    t.string "reply_to"
    t.string "subject"
    t.text "text_body"
    t.text "html_body"
    t.string "in_reply_to"
    t.text "references_header"
    t.string "idempotency_key"
    t.string "postmark_message_id"
    t.string "error"
    t.datetime "sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_key_id", "idempotency_key"], name: "index_outbound_messages_on_api_key_id_and_idempotency_key", unique: true, where: "idempotency_key IS NOT NULL"
    t.index ["api_key_id"], name: "index_outbound_messages_on_api_key_id"
    t.index ["kind"], name: "index_outbound_messages_on_kind"
    t.index ["source_message_id"], name: "index_outbound_messages_on_source_message_id"
    t.index ["status"], name: "index_outbound_messages_on_status"
    t.index ["user_id"], name: "index_outbound_messages_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.string "key", null: false
    t.text "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "messages", "action_mailbox_inbound_emails", column: "inbound_email_id"
  add_foreign_key "messages", "domains"
  add_foreign_key "outbound_messages", "api_keys"
  add_foreign_key "outbound_messages", "messages", column: "source_message_id"
  add_foreign_key "outbound_messages", "users"
  add_foreign_key "sessions", "users"
end
