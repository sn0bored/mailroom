class ForwardMailer < ApplicationMailer
  ATTACHMENT_BUDGET = 9.megabytes
  layout false

  def copy(record)
    text = "Received for #{record.to_address} on #{record.received_at}\nFrom: #{record.display_from}\n\n#{record.body_text}"
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
    html = original_html(record)
    headers["X-Mailroom-Instance"] = Mailroom.instance_id
    headers["X-Mailroom-Message-Id"] = record.id.to_s
    headers["X-Mailroom-Original-To"] = record.to_address
    mail(from: Mailroom.forward_sender, to: record.domain.forward_target,
      subject: "[#{record.domain.name}] #{record.subject}", reply_to: record.from_address,
      message_stream: Mailroom.forward_stream) do |format|
      format.text { render plain: text }
      format.html { render html: html.html_safe } if html.present?
    end
  end

  private

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
