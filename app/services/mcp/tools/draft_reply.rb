module Mcp
  module Tools
    class DraftReply < BaseTool
      tool name: "draft_reply",
           description: "Create a reply DRAFT to a message. Nothing is sent: the owner reviews and sends it from the Mailroom inbox.",
           scope: "mail:draft",
           schema: {
             type: "object",
             properties: {
               id: { type: "integer", description: "Message to reply to" },
               text_body: { type: "string", maxLength: 20_000 },
               reply_all: { type: "boolean", default: false }
             },
             required: [ "id", "text_body" ],
             additionalProperties: false
           }

      def call
        message = Message.find(integer_arg(:id, required: true))
        text = string_arg(:text_body, max: 20_000, required: true)
        raise ArgumentError, "message has no sender to reply to" if message.from_address.blank?
        raise ArgumentError, "message was not routed to one of your addresses" if message.to_address.blank?

        subject = message.subject.to_s
        subject = "Re: #{subject}" unless subject.match?(/\ARe:/i)
        draft = OutboundMessage.create!(
          kind: "reply", status: "draft", api_key: api_key, source_message: message,
          from_address: message.to_address,
          to_addresses: [ message.reply_to.presence || message.from_address ],
          cc_addresses: bool_arg(:reply_all) ? reply_all_cc(message) : [],
          subject: subject, text_body: text,
          in_reply_to: message.rfc822_message_id,
          references_header: [ message.references_header, message.rfc822_message_id ].compact_blank.join(" ")
        )
        audit("mcp.draft_reply", target: draft)
        text_result("draft #{draft.id} created (not sent). The owner can review it at /drafts/#{draft.id}.",
                    { draft_id: draft.id, path: "/drafts/#{draft.id}", status: draft.status })
      end

      private

      def reply_all_cc(message)
        parsed = Mail.new(message.raw_source)
        (Array(parsed.to) + Array(parsed.cc)).map(&:downcase).uniq - [ message.to_address, message.from_address ].compact
      rescue StandardError
        []
      end
    end
  end
end
