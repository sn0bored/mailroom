class OutboundMailer < ApplicationMailer
  LOOP_MARKED_KINDS = %w[forward_copy probe].freeze
  layout false

  # Named compose, not message: Action Mailer already has a message reader.
  def compose(record)
    # Only mail addressed back to Mailroom or its owner carries the loop marker. A reply goes to a
    # stranger, who must not learn a value that would make Mailroom skip their forward copies.
    if LOOP_MARKED_KINDS.include?(record.kind)
      message_id = LoopMarker.message_id_for(record.from_address)
      headers["Message-ID"] = message_id
      headers[LoopMarker::HEADER] = LoopMarker.stamp(message_id)
    end
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
