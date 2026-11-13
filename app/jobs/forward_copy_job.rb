# Claims mirror OutboundDeliveryJob: only a later execution of the owning job can retry
# a sending row. Transport retries remain at-least-once if the provider accepted a copy
# but its response was lost. A same-execution redispatch must never send again.
class ForwardCopyJob < ApplicationJob
  FORWARD_COPIES_PER_SENDER_PER_HOUR = Integer(ENV.fetch("MAILROOM_FORWARD_PER_SENDER_HOURLY", "5"))

  retry_on(*TRANSPORT_ERRORS, wait: 5.seconds, attempts: 3) do |job, error|
    message = Message.find_by(id: job.arguments.first)
    job.mark_failed(message, error) if message
  end

  def perform(message_id)
    message = claim(message_id)
    return unless message
    if message.blocked? || BlockedSender.blocks?(message.from_address)
      message.update!(blocked: true, forward_status: "skipped:blocked")
      return
    end
    if message.domain.nil?
      message.update!(forward_status: "skipped:unrouted")
      return
    end
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
    record_sent(message)
  rescue *TRANSPORT_ERRORS
    raise
  rescue StandardError => error
    raise unless message
    mark_failed(message, error)
  end

  def mark_failed(message, error)
    Message.where(id: message.id, forward_status: "sending", forward_job_id: job_id,
      forward_attempt: executions).update_all(forward_status: "failed:#{error.class.name}", updated_at: Time.current)
  end

  private

  def claim(id)
    claimable = Message.where(id: id, forward_status: "queued")
      .or(Message.where(id: id, forward_status: "sending", forward_job_id: job_id).where("forward_attempt < ?", executions))
    claimed = claimable.update_all(forward_status: "sending", forward_job_id: job_id,
      forward_attempt: executions, updated_at: Time.current)
    return Message.find(id) if claimed == 1

    Rails.logger.info("ForwardCopyJob: skipped message #{id} for job #{job_id} execution #{executions}; no claim available")
    nil
  end

  def record_sent(message)
    message.update_columns(forward_status: "sent", updated_at: Time.current)
    Audit.record("forward.sent", target: message)
  rescue StandardError => error
    # Never retry after provider acceptance, even for a transport-class bookkeeping error.
    # If recording sent itself fails, the sweep reports an unknown outcome without resending.
    Rails.logger.error("ForwardCopyJob: message #{message.id} was delivered, but recording it failed (#{error.class.name})")
  end
end
