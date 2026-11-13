# Every inbound message lands here. It never raises out: a message we cannot route or parse is still
# stored, because the one thing an inbox must not do is lose mail.
class IntakeMailbox < ApplicationMailbox
  DUPLICATE_WINDOW = 48.hours
  PROBE_LOCAL_PART = /\Aprobe-([0-9a-f]+)\z/i
  # Real mail nests a handful of levels. Past this we keep the raw message and parse nothing.
  MAX_MIME_DEPTH = 32

  def process
    depth = Intake::MimeDepth.call(inbound_email.source, limit: MAX_MIME_DEPTH)
    return store_too_deep if depth > MAX_MIME_DEPTH

    Intake::MimeDepth.enforce!(mail, limit: MAX_MIME_DEPTH)
    resolution = Intake::RecipientResolver.call(mail)

    same_id = same_message_id_for_target(resolution)
    # Legacy rows with a null digest cannot prove identity and are never merged.
    if (existing = same_id.find { |prior| prior.raw_body_digest.present? && prior.raw_body_digest == raw_body_digest })
      merge_duplicate(existing, resolution)
      return
    end

    builder = Intake::MessageBuilder.new(inbound_email, mail, resolution)
    message = builder.call
    probe = probe?(message)
    # A probe is our own mail coming back on purpose; anything else carrying our instance header is a loop.
    message.routed_via = "loop" if loop? && !probe
    message.blocked = BlockedSender.blocks?(message.from_address)
    message.raw_body_digest = raw_body_digest
    # Same Message-ID, different content: different mail, stored and forwarded as usual, with a note.
    message.routing_trace = Array(message.routing_trace) + [ { "header" => "same_message_id", "address" => "message:#{same_id.first.id}" } ] if same_id.any?
    message.save!
    builder.attach_to(message)

    message.domain&.update!(last_received_at: Time.current)
    message.domain.update!(probe_received_at: Time.current) if probe

    dispatch_forward_copy(message, probe: probe)
  rescue Intake::MimeDepth::MimeTooDeep
    store_too_deep
  # SystemStackError is not a StandardError; left unrescued it strands the email in processing.
  rescue StandardError, SystemStackError => e
    store_fallback(e)
  end

  private

  # Rows with this Message-ID from the last 48 hours that went where this delivery would go: the
  # same forward target or, when this one has none, any of them (nothing to forward, nothing to
  # lose). A distinct target is a genuine separate delivery and gets its own row and copy.
  #
  # Only matching content makes one of them a duplicate to merge into. Message-IDs are chosen by
  # the sender, so one who copies a real ID and arrives first must not swallow the real message:
  # same ID with different sender, recipients, subject or body is different mail.
  def same_message_id_for_target(resolution)
    id = mail.message_id.presence or return []
    prior = Message.where(rfc822_message_id: id)
                   .where("received_at > ?", DUPLICATE_WINDOW.ago)
                   .order(:received_at, :id).to_a
    return prior if prior.empty?
    target = forward_target_for(resolution)
    target.blank? ? prior : prior.select { |m| m.domain&.forward_target == target }
  rescue StandardError => e
    Rails.logger.warn("[intake] duplicate check failed for inbound_email #{inbound_email.id}: #{e.class}")
    []
  end

  # Keep the historical column name, but include identity headers as well as the raw body.
  # Unfold headers and normalise line endings; delivery-path headers may still differ.
  def raw_body_digest
    @raw_body_digest ||= begin
      body = inbound_email.source.to_s.b.split(/\r?\n\r?\n/, 2)[1].to_s
      fields = MailHeaders.fields(inbound_email.source)
      values = %w[from to cc subject].map do |name|
        fields.select { |field_name, _| field_name == name }.map do |_, value|
          value.to_s.b.gsub(/\r\n?/, "\n").gsub(/\n[ \t]+/, " ").gsub(/[ \t]+/, " ").strip
        end
      end
      # Length framing preserves field/value boundaries, even for malformed header bytes.
      digest = Digest::SHA256.new
      values.each do |fields|
        digest << "#{fields.size}:"
        fields.each { |value| digest << "#{value.bytesize}:" << value }
      end
      digest << body.gsub(/\r\n?/, "\n")
      digest.hexdigest
    end
  end

  def forward_target_for(resolution)
    domain = resolution.primary && Domain.for_address(resolution.primary)
    domain&.forward_target
  end

  def merge_duplicate(existing, resolution)
    existing.update!(
      matched_addresses: (Array(existing.matched_addresses) + resolution.matches).uniq.first(Intake::RecipientResolver::MAX_MATCHES),
      routing_trace: Array(existing.routing_trace) + [ { "header" => "duplicate", "address" => "inbound_email:#{inbound_email.id}" } ]
    )
  end

  # Our own forward copy or probe coming back: the loop marker must match this message's Message-ID,
  # so a marker lifted from one message does not mark any other.
  def loop?
    markers = mail.header.fields.select { |f| f.name.to_s.casecmp?(LoopMarker::HEADER) }
    markers.any? { |f| LoopMarker.valid?(mail.message_id, f.value.to_s) }
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
      message.update!(forward_status: "queued")
      job.perform_later(message.id)
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

  def store_too_deep
    Message.create!(
      inbound_email: inbound_email,
      routed_via: "error",
      received_at: Time.current,
      parse_error: "MimeTooDeep",
      routing_trace: [ { "header" => "mime_depth", "address" => "over #{MAX_MIME_DEPTH} levels, not parsed" } ],
      forward_status: "skipped:mime_too_deep",
      subject: (mail.subject rescue nil),
      from_address: (Array(mail.from).first.to_s.downcase.presence rescue nil)
    )
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
