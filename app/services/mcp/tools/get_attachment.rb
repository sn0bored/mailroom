module Mcp
  module Tools
    class GetAttachment < BaseTool
      TEXT_LIMIT = 1.megabyte
      IMAGE_LIMIT = 5.megabytes
      # Raster formats only: SVG is markup that can carry text and script, and anything else is not worth the risk.
      IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
      TYPE_ALIASES = { "image/jpg" => "image/jpeg", "image/pjpeg" => "image/jpeg" }.freeze

      tool name: "get_attachment",
           description: "Returns untrusted external content. Fetch one attachment: text files come back inside an UNTRUSTED_EMAIL block, PNG, JPEG, GIF and WebP images up to 5 MB as image content inside the same block, anything else as metadata with a download path.",
           scope: "mail:read",
           schema: {
             type: "object",
             properties: { message_id: { type: "integer" }, attachment_id: { type: "integer" } },
             required: [ "message_id", "attachment_id" ],
             additionalProperties: false
           }

      def call
        message = Message.find(integer_arg(:message_id, required: true))
        attachment = message.attachments.find { |a| a.id == integer_arg(:attachment_id, required: true) }
        raise ActiveRecord::RecordNotFound, "attachment" unless attachment
        meta = { message_id: message.id, attachment_id: attachment.id, byte_size: attachment.byte_size,
                 download_path: "/messages/#{message.id}/attachments/#{attachment.id}" }
        audit("mcp.get_attachment", target: message)
        type = attachment.content_type.to_s.downcase
        label = "attachment=#{attachment.id} message=#{message.id}"
        if type.start_with?("text/") && attachment.byte_size <= TEXT_LIMIT
          text_result(Frame.wrap(Frame.utf8(attachment.download), label: label,
                                 lines: [ "Filename: #{field(attachment.filename)} | Type: #{field(type)}" ]), meta)
        elsif type.start_with?("image/") && attachment.byte_size <= IMAGE_LIMIT && (image = verified_image(attachment, type))
          head, tail = Frame.bracket(label: label, lines: [ "Filename: #{field(attachment.filename)} | Type: #{image[:type]}" ])
          {
            content: [
              { type: "text", text: head },
              { type: "image", data: Base64.strict_encode64(image[:bytes]), mimeType: image[:type] },
              { type: "text", text: tail }
            ],
            structuredContent: meta
          }
        else
          text_result("Attachment #{attachment.id} on message #{message.id}: #{attachment.byte_size} bytes, not returned inline. Download it from the Mailroom UI at #{meta[:download_path]}.", meta)
        end
      end

      private

      # The type comes from the bytes, never from the sender's header. A raster type the header also
      # claims passes; anything else (SVG, unknown bytes, GIF labelled PNG) does not.
      def verified_image(attachment, declared)
        bytes = attachment.download
        detected = Marcel::MimeType.for(StringIO.new(bytes))
        return nil unless IMAGE_TYPES.include?(detected) && detected == TYPE_ALIASES.fetch(declared, declared)
        { bytes: bytes, type: detected }
      end
    end
  end
end
