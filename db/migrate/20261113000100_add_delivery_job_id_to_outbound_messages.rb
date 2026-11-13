# The delivery job that claimed the message (queued -> sending). Only that job, retrying under the
# same job id after a transport error, may claim it again while it is sending.
class AddDeliveryJobIdToOutboundMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :outbound_messages, :delivery_job_id, :string
  end
end
