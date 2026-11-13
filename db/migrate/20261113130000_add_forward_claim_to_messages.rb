class AddForwardClaimToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :forward_job_id, :string
    add_column :messages, :forward_attempt, :integer
  end
end
