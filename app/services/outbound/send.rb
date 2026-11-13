module Outbound
  class Send
    class NotAllowed < StandardError; end

    def self.call(outbound_message, actor: nil)
      record = outbound_message
      raise NotAllowed, "message must be draft or queued" unless %w[draft queued].include?(record.status)
      raise NotAllowed, "no mail provider configured (set POSTMARK_SERVER_TOKEN)" unless Mailroom.sending_configured?
      domain = Domain.active.find_by(name: record.from_domain)
      unless domain&.send_enabled?
        reason = record.kind == "probe" ? "probe sender's domain must be active and send_enabled" : "sender domain is inactive, unknown, or sending is disabled"
        raise NotAllowed, reason
      end
      if record.api_key && !record.api_key.may_send_from?(record.from_domain)
        raise NotAllowed, "key cannot send from this domain"
      end
      raise NotAllowed, "recipients required" if record.recipients.reject(&:blank?).empty?

      record.user ||= actor if actor.is_a?(User)
      record.api_key ||= actor if actor.is_a?(ApiKey)
      # Check the supplied actor as well when it becomes the message's key.
      if record.api_key && !record.api_key.may_send_from?(record.from_domain)
        raise NotAllowed, "key cannot send from this domain"
      end
      was_new = record.new_record?
      previous_status = record.status_in_database
      record.update!(status: "queued", error: nil)
      enqueue_delivery(record, was_new:, previous_status:)
      record
    end

    # The job is enqueued outside the row's database (Solid Queue keeps its own), so the two cannot
    # share a transaction. When the enqueue fails, undo the queued status before re-raising: otherwise the row claims a delivery no
    # job will make, and an API retry with the same idempotency key would replay it as queued. A
    # message that did not exist before the call is removed, so a retry is judged from scratch; an
    # existing one (an owner's draft) is never destroyed and goes back to its earlier status.
    #
    # Still open: a process killed between the insert and the enqueue leaves a queued row with no
    # job. A sweeper that re-enqueues stale queued rows would cover it, but OutboundDeliveryJob only
    # reads status == "queued" before delivering and does not claim the row atomically, so two jobs
    # for one row can both deliver. The job needs an atomic claim before such a sweeper is safe.
    def self.enqueue_delivery(record, was_new:, previous_status:)
      enqueue_error = nil
      enqueued = OutboundDeliveryJob.perform_later(record.id) { |job| enqueue_error = job.enqueue_error }
      raise enqueue_error || ActiveJob::EnqueueError.new("delivery job was not enqueued") unless enqueued
    rescue StandardError => error
      if was_new
        record.destroy!
      else
        record.update_columns(status: previous_status, error: "could not queue for delivery: #{error.class.name}")
      end
      raise
    end
    private_class_method :enqueue_delivery
  end
end
