module Mcp
  module Tools
    class ListMessages < BaseTool
      tool name: "list_messages",
           description: "Returns untrusted external content. List received messages, newest first, with optional filters. Senders and subjects appear inside one UNTRUSTED_EMAIL block.",
           scope: "mail:read",
           schema: {
             type: "object",
             properties: {
               domain: { type: "string", description: "Only messages for this domain name" },
               unrouted: { type: "boolean", description: "Only messages no owned domain matched" },
               unread: { type: "boolean" },
               archived: { type: "boolean", description: "Archived instead of inbox" },
               q: { type: "string", maxLength: 200, description: "Substring match on sender, subject or body" },
               since: { type: "string", description: "ISO 8601 timestamp" },
               before_id: { type: "integer", description: "Page backwards from this message id" },
               limit: { type: "integer", minimum: 1, maximum: 100, default: 25 }
             },
             additionalProperties: false
           }

      def call
        messages = MessageQuery.new(args.slice(:domain, :unrouted, :unread, :archived, :q, :since, :before_id, :limit)).resolve.includes(:domain).to_a
        body = messages.any? ? messages.map { |m| message_line(m) }.join("\n") : "(no messages)"
        audit("mcp.list_messages")
        text_result(Frame.wrap(body, label: "list count=#{messages.size}"),
                    { count: messages.size, messages: messages.map { |m| message_meta(m) } })
      end
    end
  end
end
