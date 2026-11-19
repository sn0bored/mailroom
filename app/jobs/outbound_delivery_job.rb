# Delivers one outbound message.
#
# Delivery semantics:
# - A job delivers only after it claims the row: one conditional UPDATE moves it from queued to
#   sending and stamps this job's id and execution count on it. A duplicate job for the same row
#   (a second enqueue, or a sweep re-enqueueing a row whose job looked lost) cannot claim it and stops.
# - A transport error retries this same job under the same job id, and the claim lets that job,
#   and no other, take its own sending row again only with a higher execution count. Redispatching
#   the same execution after a worker shutdown cannot deliver again.
# - Delivery is therefore at-least-once on transport retries: if the provider accepted the message
#   but the response was lost (a timeout), the retry sends it a second time.
# - Once deliver_now returns, the provider has the message. It is recorded as sent before anything
#   else, and nothing after that point can retry it or mark it failed.
class OutboundDeliveryJob < ApplicationJob
  retry_on(*TRANSPORT_ERRORS, wait: 5.seconds, attempts: 3) do |job, error|
    job.mark_failed(OutboundMessage.find(job.arguments.first), error)
  end

  def perform(id)
    record = claim(id)
    return unless record

    begin
      delivery = OutboundMailer.compose(record).deliver_now
    rescue *TRANSPORT_ERRORS
      raise
    rescue StandardError => error
      return mark_failed(record, error)
    end
    record_sent(record, delivery)
  end

  def mark_failed(record, error)
    record.update!(status: "failed", error: error.class.name)
    Audit.record("outbound.failed", actor: record.api_key || record.user,
      target: record, outcome: "failed", error: error)
  end

  private

  # Returns the record when this job holds the claim, nil when the row is gone, finished, or
  # claimed by another job or the same execution. Legacy claims with no recorded attempt cannot
  # be safely retried; the sweep will report their outcome as unknown if they never finish.
  def claim(id)
    claimable = OutboundMessage.where(id: id, status: "queued")
      .or(OutboundMessage.where(id: id, status: "sending", delivery_job_id: job_id).where("delivery_attempt < ?", executions))
    claimed = claimable.update_all(status: "sending", delivery_job_id: job_id,
      delivery_attempt: executions, updated_at: Time.current)
    return OutboundMessage.find(id) if claimed == 1

    Rails.logger.info("OutboundDeliveryJob: skipped message #{id} for job #{job_id} execution #{executions}; no claim available")
    nil
  end

  def record_sent(record, delivery)
    record.update_columns(status: "sent", sent_at: Time.current, error: nil, updated_at: Time.current)

    provider_id = delivery.postmark_message_id if delivery.respond_to?(:postmark_message_id)
    record.update_columns(postmark_message_id: provider_id.presence || delivery.message_id)
    Audit.record("outbound.sent", actor: record.api_key || record.user, target: record)
  rescue StandardError => error
    # Never re-raise here: a transport-class error would retry and send the message again. If even
    # the sent status did not stick, the row stays sending, and OutboundSweepJob later reports its
    # outcome as unknown instead of resending it.
    Rails.logger.error("OutboundDeliveryJob: message #{record.id} was delivered, but recording it failed (#{error.class.name})")
  end
end
