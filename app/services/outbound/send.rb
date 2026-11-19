module Outbound
  class Send
    class NotAllowed < StandardError; end
    # The delivery job could not be enqueued; undo the queued state unless delivery already started.
    class NotQueued < StandardError; end

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
      record.assign_attributes(status: "queued", error: nil)
      if was_new
        record.save!
      else
        record.validate!
        # Keep pending edits and actor attribution in the same conditional update as the status.
        attributes = record.changes.transform_values(&:last).merge(status: "queued", error: nil, updated_at: Time.current)
        updated = OutboundMessage.where(id: record.id, status: previous_status).update_all(attributes)
        raise NotAllowed, "message is no longer a draft" if updated == 0

        record.reload
      end
      enqueue_delivery(record, was_new:, previous_status:)
      record
    end

    # The job is enqueued outside the row's database (Solid Queue keeps its own), so the two cannot
    # share a transaction. When the enqueue fails, undo the queued status and raise NotQueued:
    # otherwise the row claims a delivery no job will make, and an API retry with the same
    # idempotency key would replay it as queued. A message that did not exist before the call is
    # removed, so a retry is judged from scratch; an existing one (an owner's draft) is never
    # destroyed and goes back to its earlier status.
    #
    # A process killed between the insert and the enqueue still leaves a queued row with no job.
    # OutboundSweepJob re-enqueues those after a grace period, and the delivery job's claim makes
    # a duplicate job harmless if the original turns out to be only late.
    def self.enqueue_delivery(record, was_new:, previous_status:)
      begin
        enqueue_error = nil
        enqueued = OutboundDeliveryJob.perform_later(record.id) { |job| enqueue_error = job.enqueue_error }
        raise enqueue_error || ActiveJob::EnqueueError.new("delivery job was not enqueued") unless enqueued
      rescue StandardError => error
        reason = "could not queue for delivery: #{error.class.name}"
        queued = OutboundMessage.where(id: record.id, status: "queued")
        if was_new
          queued.delete_all
        else
          queued.update_all(status: previous_status, error: reason, updated_at: Time.current)
        end
        raise NotQueued, reason
      end

      # A worker may already have claimed the row. Never replace its job id with this enqueue's
      # id, and never roll back a successful enqueue if recording it fails.
      OutboundMessage.where(id: record.id, status: "queued", delivery_job_id: nil)
        .update_all(delivery_job_id: enqueued.job_id, updated_at: Time.current)
      record.reload
    end
    private_class_method :enqueue_delivery
  end
end
