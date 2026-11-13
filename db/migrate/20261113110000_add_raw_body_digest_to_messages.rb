class AddRawBodyDigestToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :raw_body_digest, :string
  end
end
