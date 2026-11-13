class ForwardMailer < ApplicationMailer
  ATTACHMENT_BUDGET = 9.megabytes
  UNVERIFIED_TAG = "[unverified sender]"
  BANNER_STYLE = "font-family:sans-serif;font-size:13px;line-height:1.4;color:#222;background:#f4f4f4;" \
                 "border:1px solid #ccc;padding:8px 12px;margin:0 0 16px"
  layout false

  # The copy comes from the owner's own domain, so it must never let a stranger's mail pass for mail
  # that domain vouches for: both parts name the original sender, the HTML is sanitized, and a sender
  # whose domain did not authenticate is tagged in the subject.
  def copy(record)
    auth = record.sender_authentication
    text = "Received for #{record.to_address} on #{record.received_at}\nFrom: #{record.display_from}\n"
    text += "Sender check: #{auth.summary}\n" if auth.known?
    text += "\n#{record.body_text}"
    total = 0
    items = record.attachments.to_a
    items.each_with_index do |attachment, index|
      total += attachment.byte_size
      if total > ATTACHMENT_BUDGET
        text += "\n\n#{items.length - index} attachment(s) not forwarded; open message #{record.id} in Mailroom"
        break
      end
      attachments[attachment.filename.to_s] = { mime_type: attachment.content_type, content: attachment.download }
    end
    html = forwarded_html(record, auth)
    message_id = LoopMarker.message_id_for(Mailroom.forward_sender)
    headers["Message-ID"] = message_id
    headers[LoopMarker::HEADER] = LoopMarker.stamp(message_id)
    headers["X-Mailroom-Message-Id"] = record.id.to_s
    headers["X-Mailroom-Original-To"] = record.to_address
    subject = "[#{record.domain.name}] #{record.subject}"
    subject = "#{UNVERIFIED_TAG} #{subject}" if auth.failed?
    mail(from: Mailroom.forward_sender, to: record.domain.forward_target,
      subject: subject, reply_to: record.from_address,
      message_stream: Mailroom.forward_stream) do |format|
      format.text { render plain: text }
      format.html { render html: html.html_safe } if html.present?
    end
  end

  private

  # Banner plus sanitized original, or nil to forward the text part alone (no HTML, or sanitizing failed).
  def forwarded_html(record, auth)
    html = original_html(record)
    return nil if html.blank?
    clean = Rails::HTML5::SafeListSanitizer.new.sanitize(html, scrubber: ForwardHtmlScrubber.new)
    clean.present? ? provenance_banner(record, auth) + clean : nil
  rescue StandardError
    nil
  end

  def provenance_banner(record, auth)
    rows = [ [ "From", record.display_from ], [ "To", record.to_address ], [ "Date", (record.sent_at || record.received_at).to_s ] ]
    rows << [ "Sender check", auth.summary ] if auth.known?
    lines = rows.map { |label, value| "#{label}: #{ERB::Util.html_escape(value)}" }
    %(<div style="#{BANNER_STYLE}"><strong>Forwarded by Mailroom</strong><br>#{lines.join('<br>')}</div>)
  end

  def original_html(record)
    return nil unless record.has_html?
    mail = Mail.new(record.raw_source)
    # Mirror Intake::MessageBuilder#html_source: a single-part text/html mail has no html_part,
    # so its HTML body lives in the mail itself. Reading only html_part dropped it on forward.
    mail.multipart? ? mail.html_part&.decoded : mail.decoded
  rescue StandardError
    nil
  end
end
