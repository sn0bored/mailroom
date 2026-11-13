class ForwardCopyJob < ApplicationJob
  FORWARD_COPIES_PER_SENDER_PER_HOUR = Integer(ENV.fetch("MAILROOM_FORWARD_PER_SENDER_HOURLY", "5"))

  retry_on(*TRANSPORT_ERRORS, wait: 5.seconds, attempts: 3) do |job, error|
    message = Message.find_by(id: job.arguments.first)
    message&.update!(forward_status: "failed:#{error.class.name}")
  end

  def perform(message_id)
    message = Message.find(message_id)
    if message.blocked? || BlockedSender.blocks?(message.from_address)
      message.update!(blocked: true, forward_status: "skipped:blocked")
      return
    end
    return if message.domain.nil?
    if message.domain.forward_target.blank?
      message.update!(forward_status: "skipped:no_target")
      return
    end
    if message.domain.forward_mode == "off"
      message.update!(forward_status: "skipped:forward_off")
      return
    end
    unless message.domain.forward_copy_for?(message)
      message.update!(forward_status: "skipped:not_listed")
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

    # Only consume a throttle slot on the first attempt; a transport-error retry is the
    # same already-admitted copy and must not re-increment the per-sender hourly counter.
    if executions <= 1 && !ForwardThrottle.allow?(message.from_address)
      message.update!(forward_status: "skipped:throttled")
      return
    end

    ForwardMailer.copy(message).deliver_now
    message.update!(forward_status: "sent")
  rescue *TRANSPORT_ERRORS
    raise
  rescue StandardError => error
    raise unless message
    message.update!(forward_status: "failed:#{error.class.name}")
  end
end
