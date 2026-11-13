# Recovers outbound mail and forward copies whose delivery job went missing. Solid Queue's scheduler runs it every few
# minutes (config/recurring.yml); it never sends anything itself.
#
# - Queued for longer than QUEUED_GRACE: the job was lost, for example because the process died
#   between storing the row and enqueueing its job. Enqueue another. Solid Queue's tables are not
#   consulted: if the original job is only late, the two race for OutboundDeliveryJob's claim and
#   exactly one delivers. The row is touched so the next sweep waits another grace period.
# - Sending for longer than SENDING_TIMEOUT: a job claimed it and never reported back, so the
#   provider may or may not have it. Mark it failed and never resend it automatically.
class OutboundSweepJob < ApplicationJob
  QUEUED_GRACE = 15.minutes
  SENDING_TIMEOUT = 1.hour
  UNKNOWN_OUTCOME = "delivery outcome unknown; check the provider before resending".freeze

  def perform
    requeue_lost_jobs
    fail_stale_deliveries
    fail_stale_forward_copies
  end

  private

  def requeue_lost_jobs
    cutoff = QUEUED_GRACE.ago
    OutboundMessage.where(status: "queued", updated_at: ...cutoff).find_each do |record|
      next unless OutboundMessage.where(id: record.id, status: "queued", updated_at: ...cutoff)
        .update_all(updated_at: Time.current) == 1

      OutboundDeliveryJob.perform_later(record.id)
      Audit.record("outbound.requeued", actor: record.api_key || record.user, target: record)
    end
  end

  def fail_stale_deliveries
    cutoff = SENDING_TIMEOUT.ago
    OutboundMessage.where(status: "sending", updated_at: ...cutoff).find_each do |record|
      next unless OutboundMessage.where(id: record.id, status: "sending", updated_at: ...cutoff)
        .update_all(status: "failed", error: UNKNOWN_OUTCOME, updated_at: Time.current) == 1

      Audit.record("outbound.failed", actor: record.api_key || record.user, target: record, outcome: "failed")
    end
  end

  def fail_stale_forward_copies
    Message.where(forward_status: "sending", updated_at: ...SENDING_TIMEOUT.ago)
      .update_all(forward_status: "failed:outcome_unknown", updated_at: Time.current)
  end
end
