class OutboundMailer < ApplicationMailer
  layout false

  # Named compose, not message: Action Mailer already has a message reader.
  def compose(record)
    headers["X-Mailroom-Instance"] = Mailroom.instance_id
    headers["X-Mailroom-Message-Id"] = record.id.to_s
    headers["In-Reply-To"] = record.in_reply_to if record.in_reply_to.present?
    headers["References"] = record.references_header if record.references_header.present?
    options = { from: record.from_address, to: record.to_addresses,
      cc: record.cc_addresses, bcc: record.bcc_addresses, subject: record.subject }
    options[:reply_to] = record.reply_to if record.reply_to.present?
    options[:message_stream] = Mailroom.forward_stream if %w[forward_copy probe].include?(record.kind)
    mail(**options) do |format|
      format.text { render plain: record.text_body.to_s }
      format.html { render html: record.html_body.html_safe } if record.html_body.present?
    end
  end
end
