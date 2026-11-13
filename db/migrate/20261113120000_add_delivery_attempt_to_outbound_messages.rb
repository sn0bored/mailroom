class AddDeliveryAttemptToOutboundMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :outbound_messages, :delivery_attempt, :integer
  end
end
