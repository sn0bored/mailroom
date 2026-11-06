class CreateApiKeys < ActiveRecord::Migration[8.0]
  def change
    create_table :api_keys do |t|
      t.string :name, null: false
      t.string :token_prefix, null: false
      t.string :token_digest, null: false
      t.json :scopes, null: false
      t.json :allowed_from_domains, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :api_keys, :token_digest, unique: true
  end
end
