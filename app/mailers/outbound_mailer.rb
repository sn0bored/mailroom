class OutboundMailer < ApplicationMailer
  LOOP_MARKED_KINDS = %w[forward_copy probe].freeze
  layout false

  # Named compose, not message: Action Mailer already has a message reader.
  def compose(record)
    message_id = new_message_id(record.from_address)
    headers["Message-ID"] = message_id
    # Only mail addressed back to Mailroom or its owner carries the loop marker. A reply goes to a
    # stranger, who must not learn a value that would make Mailroom skip their forward copies.
    headers[LoopMarker::HEADER] = LoopMarker.stamp(message_id) if LOOP_MARKED_KINDS.include?(record.kind)
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
