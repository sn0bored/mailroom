# Every inbound message lands here. It never raises out: a message we cannot route or parse is still
# stored, because the one thing an inbox must not do is lose mail.
class IntakeMailbox < ApplicationMailbox
  DUPLICATE_WINDOW = 48.hours
  PROBE_LOCAL_PART = /\Aprobe-([0-9a-f]+)\z/i

  def process
    resolution = Intake::RecipientResolver.call(mail)

    if (existing = duplicate_of(resolution))
      merge_duplicate(existing, resolution)
      return
    end

    builder = Intake::MessageBuilder.new(inbound_email, mail, resolution)
    message = builder.call
    probe = probe?(message)
    # A probe is our own mail coming back on purpose; anything else carrying our instance header is a loop.
    message.routed_via = "loop" if loop? && !probe
    message.blocked = BlockedSender.blocks?(message.from_address)
    message.save!
    builder.attach_to(message)

    message.domain&.update!(last_received_at: Time.current)
    message.domain.update!(probe_received_at: Time.current) if probe

    dispatch_forward_copy(message, probe: probe)
  rescue StandardError => e
    store_fallback(e)
  end

  private

  def duplicate_of(resolution)
    id = mail.message_id.presence or return nil
    Message.where(rfc822_message_id: id).where("received_at > ?", DUPLICATE_WINDOW.ago).first
  rescue StandardError
    nil
  end

  def merge_duplicate(existing, resolution)
    existing.update!(
      matched_addresses: (Array(existing.matched_addresses) + resolution.matches).uniq,
      routing_trace: Array(existing.routing_trace) + [ { "header" => "duplicate", "address" => "inbound_email:#{inbound_email.id}" } ]
    )
  end

  def loop?
    value = mail.header.fields.find { |f| f.name.to_s.casecmp?("X-Mailroom-Instance") }&.value.to_s
    value.present? && value == Mailroom.instance_id.to_s
  end

  def probe?(message)
    return false unless message.domain && message.to_address
    local = message.to_address.split("@").first.to_s
    token = local[PROBE_LOCAL_PART, 1]
    token.present? && message.domain.probe_token.present? && token.casecmp?(message.domain.probe_token)
  end

  def dispatch_forward_copy(message, probe:)
    reason = forward_skip_reason(message, probe: probe)
    if reason
      message.update!(forward_status: "skipped:#{reason}")
      return
    end
    job = "ForwardCopyJob".safe_constantize
    if job
      job.perform_later(message.id)
      message.update!(forward_status: "queued")
    else
      message.update!(forward_status: "skipped:no_forwarder")
    end
  end

  def forward_skip_reason(message, probe:)
    return "blocked" if message.blocked?
    return "probe" if probe
    return "loop" if message.routed_via == "loop"
    return "unrouted" if message.domain.nil?
    return "no_target" if message.domain.forward_target.blank?
    return "forward_off" if message.domain.forward_mode == "off"
    return "not_listed" unless message.domain.forward_copy_for?(message)
    return "no_sender" if Mailroom.forward_sender.blank?
    return "no_provider" unless Mailroom.sending_configured?
    return "list" if message.list_mail
    return "spam" if message.spam?(message.domain.forward_copy_max_spam)
    nil
  end

  def store_fallback(error)
    Rails.logger.error("[intake] inbound_email #{inbound_email.id} failed: #{error.class}")
    return if Message.exists?(inbound_email_id: inbound_email.id)
    Message.create!(
      inbound_email: inbound_email,
      routed_via: "error",
      received_at: Time.current,
      parse_error: error.class.name,
      subject: (mail.subject rescue nil)
    )
  rescue StandardError => e
    Rails.logger.error("[intake] fallback store failed for inbound_email #{inbound_email.id}: #{e.class}")
  end
end
