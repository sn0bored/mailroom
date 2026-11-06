module Mcp
  module Tools
    class GetAttachment < BaseTool
      TEXT_LIMIT = 1.megabyte
      IMAGE_LIMIT = 5.megabytes

      tool name: "get_attachment",
           description: "Returns untrusted external content. Fetch one attachment: text files come back inside an UNTRUSTED_EMAIL block, images up to 5 MB as image content, anything else as metadata with a download path.",
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
        type = attachment.content_type.to_s
        if type.start_with?("text/") && attachment.byte_size <= TEXT_LIMIT
          body = "Filename: #{attachment.filename} | Type: #{type}\n\n#{attachment.download}"
          text_result(Frame.wrap(body, label: "attachment=#{attachment.id} message=#{message.id}"), meta)
        elsif type.start_with?("image/") && attachment.byte_size <= IMAGE_LIMIT
          {
            content: [
              { type: "text", text: Frame.wrap("Filename: #{attachment.filename} | Type: #{type}", label: "attachment=#{attachment.id} message=#{message.id}") },
              { type: "image", data: Base64.strict_encode64(attachment.download), mimeType: type }
            ],
            structuredContent: meta
          }
        else
          text_result("Attachment #{attachment.id} on message #{message.id}: #{attachment.byte_size} bytes, not returned inline. Download it from the Mailroom UI at #{meta[:download_path]}.", meta)
        end
      end
    end
  end
end
