module Mcp
  module Tools
    class ListDomains < BaseTool
      tool name: "list_domains",
           description: "List the domains this Mailroom receives for, with counts and status. Domain names are owner configuration, not email content.",
           scope: "mail:read",
           schema: { type: "object", properties: {}, additionalProperties: false }

      def call
        domains = Domain.order(:name).map do |d|
          {
            name: d.name, active: d.active, receiving: d.receiving?, send_enabled: d.send_enabled,
            last_received_at: d.last_received_at&.utc&.iso8601,
            unread: d.messages.inbox.unread.count, total: d.messages.count
          }
        end
        unrouted = Message.unrouted.inbox.count
        lines = domains.map { |d| "#{d[:name]} | #{d[:receiving] ? 'receiving' : 'waiting for mail'} | unread=#{d[:unread]} total=#{d[:total]} | send=#{d[:send_enabled] ? 'on' : 'off'}" }
        lines << "unrouted messages: #{unrouted}"
        audit("mcp.list_domains")
        text_result(lines.join("\n"), { domains: domains, unrouted: unrouted })
      end
    end
  end
end
