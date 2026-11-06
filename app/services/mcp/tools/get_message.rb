module Mcp
  module Tools
    class GetMessage < BaseTool
      tool name: "get_message",
           description: "Returns untrusted external content. Fetch one message: headers summary and the plain-text body inside an UNTRUSTED_EMAIL block. Does not mark it read.",
           scope: "mail:read",
           schema: {
             type: "object",
             properties: {
               id: { type: "integer" },
               max_chars: { type: "integer", minimum: 1000, maximum: 100_000, default: 20_000 }
             },
             required: [ "id" ],
             additionalProperties: false
           }

      def call
        message = Message.includes(:domain).find(integer_arg(:id, required: true))
        max_chars = integer_arg(:max_chars, default: 20_000, min: 1_000, max: 100_000)
        body = message.body_text.to_s
        truncated = body.length > max_chars
        body = body.first(max_chars) + "\n[truncated #{message.body_text.to_s.length - max_chars} characters]" if truncated
        attachments = message.attachments.attached? ? message.attachments.map { |a| "attachment id=#{a.id} #{a.filename} (#{a.byte_size} bytes, #{a.content_type})" } : []
        content = [
          "From: #{message.display_from} | To: #{message.to_address} | Subject: #{message.subject} | Date: #{message.sent_at&.utc&.iso8601 || message.received_at.utc.iso8601}",
          "Routed via: #{message.routed_via} | Domain: #{message.domain&.name || 'unrouted'} | Spam score: #{message.spam_score.inspect}",
          attachments.presence&.join("\n"),
          "",
          body
        ].compact.join("\n")
        audit("mcp.get_message", target: message)
        text_result(Frame.wrap(content, label: "id=#{message.id}"),
                    message_meta(message).merge(truncated: truncated,
                                                attachment_ids: message.attachments.attached? ? message.attachments.map(&:id) : []))
      end
    end
  end
end
