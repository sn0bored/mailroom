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
      record.update!(status: "queued", error: nil)
      OutboundDeliveryJob.perform_later(record.id)
      record
    end
  end
end
