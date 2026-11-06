module Mcp
  module Tools
    class UpdateMessage < BaseTool
      tool name: "update_message",
           description: "Mark a message read or unread, archive or unarchive it.",
           scope: "mail:write",
           schema: {
             type: "object",
             properties: { id: { type: "integer" }, read: { type: "boolean" }, archived: { type: "boolean" } },
             required: [ "id" ],
             additionalProperties: false
           }

      def call
        message = Message.find(integer_arg(:id, required: true))
        raise ArgumentError, "pass read and/or archived" if args[:read].nil? && args[:archived].nil?
        unless args[:read].nil?
          bool_arg(:read) ? message.mark_read! : message.mark_unread!
        end
        unless args[:archived].nil?
          bool_arg(:archived) ? message.archive! : message.unarchive!
        end
        audit("mcp.update_message", target: message)
        text_result("message #{message.id} updated: read=#{message.read?} archived=#{message.archived?}",
                    { id: message.id, read: message.read?, archived: message.archived? })
      end
    end
  end
end
