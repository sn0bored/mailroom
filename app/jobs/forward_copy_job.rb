class ForwardCopyJob < ApplicationJob
  def perform(message_id)
    message = Message.find(message_id)
    return if message.domain.nil?
    unless message.domain.forwarding?
      message.update!(forward_status: "skipped:no_target")
      return
    end
    unless Mailroom.sending_configured?
      message.update!(forward_status: "skipped:no_provider")
      return
    end
    if Mailroom.forward_sender.blank?
      Rails.logger.warn("Forward copy skipped: no sender configured") unless message.forward_status == "skipped:no_sender"
      message.update!(forward_status: "skipped:no_sender")
      return
    end

    ForwardMailer.copy(message).deliver_now
    message.update!(forward_status: "sent")
  rescue StandardError => error
    raise unless message
    message.update!(forward_status: "failed:#{error.class.name}")
  end
end
