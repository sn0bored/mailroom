module Mcp
  module Tools
    class DraftReply < BaseTool
      tool name: "draft_reply",
           description: "Create a reply DRAFT to a message. Nothing is sent: the owner reviews and sends it from the Mailroom inbox. " \
                        "reply_all copies only the original sender and recipients on the owner's own domains; anyone else is left off and listed in the result.",
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
        to = [ message.reply_to.presence || message.from_address ]
        cc, left_off = bool_arg(:reply_all) ? reply_all_cc(message, to) : [ [], [] ]
        draft = OutboundMessage.create!(
          kind: "reply", status: "draft", api_key: api_key, source_message: message,
          from_address: message.to_address, to_addresses: to, cc_addresses: cc,
          subject: subject, text_body: text,
          in_reply_to: message.rfc822_message_id,
          references_header: [ message.references_header, message.rfc822_message_id ].compact_blank.join(" ")
        )
        audit("mcp.draft_reply", target: draft)
        text_result(result_text(draft, message, left_off),
                    { draft_id: draft.id, path: "/drafts/#{draft.id}", status: draft.status,
                      left_off_recipients: left_off.size })
      end

      private

      # Reply-all keeps the original sender and the recipients on the owner's own domains. Anyone
      # else on the original To or Cc was chosen by the sender, so they are left off and reported
      # rather than slipped onto a reply the owner might approve without noticing them.
      # Returns [cc, left_off].
      def reply_all_cc(message, to)
        sender = message.from_address.to_s.downcase
        excluded = [ message.to_address, *to ].map { |address| address.to_s.downcase }
        candidates = (original_recipients(message) + [ sender ]).uniq - excluded
        owned = Domain.owned_names
        candidates.partition { |address| address == sender || owned.include?(domain_of(address)) }
      end

      def original_recipients(message)
        parsed = Mail.new(message.raw_source)
        (Array(parsed.to) + Array(parsed.cc)).map { |address| address.to_s.downcase }.compact_blank
      rescue StandardError
        []
      end

      def domain_of(address)
        Mail::Address.new(address).domain.to_s.downcase
      rescue Mail::Field::ParseError
        ""
      end

      # The addresses that were left off came from the email, so they are framed as untrusted content.
      def result_text(draft, message, left_off)
        lines = [ "draft #{draft.id} created (not sent). The owner can review it at /drafts/#{draft.id}." ]
        if draft.reply_to_differs_from_sender?
          lines << "The reply goes to the message's Reply-To address, which differs from its sender. The draft page shows both."
        end
        if left_off.any?
          lines << "Reply-all left off #{left_off.size} recipient(s) who are not on the owner's domains. " \
                   "Tell the owner; they can add any that belong on the reply from the draft page."
          lines << Frame.wrap(left_off.join("\n"), label: "left_off_recipients message_id=#{message.id}")
        end
        lines.join("\n")
      end
    end
  end
end
