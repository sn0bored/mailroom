module Intake
  # Turns a parsed mail plus a routing result into an unsaved Message. Pure extraction, no I/O.
  class MessageBuilder
    LIST_PRECEDENCE = %w[bulk list junk].freeze
    SNIPPET_LENGTH = 200

    def self.call(inbound_email, mail, resolution)
      new(inbound_email, mail, resolution).call
    end

    def initialize(inbound_email, mail, resolution)
      @inbound_email = inbound_email
      @mail = mail
      @resolution = resolution
    end

    def call
      body = body_text
      Message.new(
        inbound_email: @inbound_email,
        domain: @resolution.primary && Domain.for_address(@resolution.primary),
        to_address: @resolution.primary,
        matched_addresses: @resolution.matches,
        routed_via: @resolution.routed_via,
        routing_trace: @resolution.trace,
        rfc822_message_id: @mail.message_id.presence,
        in_reply_to: Array(@mail.in_reply_to).first.presence,
        references_header: Array(@mail.references).join(" ").presence,
        from_address: Array(@mail.from).first.to_s.downcase.presence,
        from_name: display_name,
        reply_to: Array(@mail.reply_to).first.to_s.downcase.presence,
        subject: utf8(@mail.subject),
        sent_at: sent_at,
        received_at: Time.current,
        body_text: body,
        has_html: html?,
        snippet: body.to_s.squish.truncate(SNIPPET_LENGTH),
        spam_score: spam_score,
        list_mail: list_mail?,
        size_bytes: size_bytes
      )
    end

    # Attachments need a saved record; call after save!.
    def attach_to(message, limit: 25.megabytes)
      @mail.attachments.each do |part|
        bytes = part.decoded
        next if bytes.bytesize > limit
        message.attachments.attach(
          io: StringIO.new(bytes),
          filename: part.filename.presence || "attachment",
          content_type: part.mime_type.presence || "application/octet-stream",
          identify: false
        )
      end
    rescue StandardError => e
      Rails.logger.warn("[intake] attachments skipped for message #{message.id}: #{e.class}")
    end

    private

    def display_name
      name = @mail[:from]&.display_names&.first
      utf8(name).presence
    rescue StandardError
      nil
    end

    def sent_at
      @mail.date&.to_time
    rescue StandardError
      nil
    end

    def body_text
      text = if @mail.multipart?
        @mail.text_part&.decoded
      elsif @mail.mime_type.nil? || @mail.mime_type == "text/plain"
        @mail.decoded
      end
      text = strip_html(html_source) if text.blank? && html?
      utf8(text)
    rescue StandardError
      nil
    end

    def html?
      @mail.multipart? ? @mail.html_part.present? : @mail.mime_type == "text/html"
    rescue StandardError
      false
    end

    def html_source
      @mail.multipart? ? @mail.html_part&.decoded : @mail.decoded
    end

    def strip_html(html)
      return nil if html.blank?
      Rails::HTML5::FullSanitizer.new.sanitize(utf8(html)).to_s.squish
    end

    def spam_score
      value = header("X-Spam-Score") || header("X-Mailroom-Spam-Score")
      value.present? ? Float(value.strip) : nil
    rescue ArgumentError, TypeError
      nil
    end

    def list_mail?
      return true if header("List-Id").present?
      return true if LIST_PRECEDENCE.include?(header("Precedence").to_s.strip.downcase)
      auto = header("Auto-Submitted").to_s.strip.downcase
      auto.present? && auto != "no"
    end

    def size_bytes
      @inbound_email.raw_email&.byte_size
    rescue StandardError
      nil
    end

    def header(name)
      field = @mail.header.fields.find { |f| f.name.to_s.casecmp?(name) }
      field&.value&.to_s
    end

    def utf8(text)
      return nil if text.nil?
      s = text.to_s.dup
      s = s.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
      s.valid_encoding? ? s : s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end
  end
end
