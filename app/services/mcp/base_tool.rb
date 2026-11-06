module Mcp
  class BaseTool
    class << self
      attr_reader :tool_name, :tool_description, :tool_scope, :tool_schema

      def tool(name:, description:, scope:, schema:)
        @tool_name = name
        @tool_description = description
        @tool_scope = scope
        @tool_schema = schema
      end

      def manifest
        { name: tool_name, description: tool_description, inputSchema: tool_schema }
      end

      def allowed?(api_key) = api_key.present? && api_key.allows?(tool_scope)

      def call(arguments, api_key) = new(arguments, api_key).call
    end

    def initialize(arguments, api_key)
      @args = (arguments || {}).to_h.with_indifferent_access
      @api_key = api_key
    end

    private

    attr_reader :args, :api_key

    def integer_arg(name, default: nil, min: nil, max: nil, required: false)
      value = args[name]
      raise ArgumentError, "#{name} is required" if required && value.blank?
      return default if value.blank?
      number = Integer(value)
      number = number.clamp(min, max) if min && max
      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be an integer"
    end

    def string_arg(name, max: 2000, required: false)
      value = args[name]
      raise ArgumentError, "#{name} is required" if required && value.blank?
      value.present? ? value.to_s.first(max) : nil
    end

    def bool_arg(name, default: false)
      value = args[name]
      return default if value.nil?
      [ true, "true", "1", 1 ].include?(value)
    end

    def text_result(text, structured = {})
      { content: [ { type: "text", text: text } ], structuredContent: structured }
    end

    def audit(action, target: nil, outcome: "ok", error: nil)
      Audit.record(action, actor: api_key, target: target, outcome: outcome, error: error)
    end

    def message_line(message)
      flags = []
      flags << "unread" unless message.read?
      flags << "archived" if message.archived?
      flags << "spam=#{message.spam_score}" if message.spam_score
      flags << "attachments=#{message.attachments.size}" if message.attachments.attached?
      [
        "id=#{message.id}",
        message.received_at&.utc&.iso8601,
        "domain=#{message.domain&.name || 'unrouted'}",
        "to=#{message.to_address}",
        "from=#{message.display_from}",
        "subject=#{message.subject}",
        flags.join(" ")
      ].compact.join(" | ")
    end

    def message_meta(message)
      {
        id: message.id,
        domain: message.domain&.name,
        received_at: message.received_at&.utc&.iso8601,
        read: message.read?,
        archived: message.archived?,
        spam_score: message.spam_score,
        list_mail: message.list_mail,
        size_bytes: message.size_bytes,
        attachments: message.attachments.attached? ? message.attachments.size : 0
      }
    end
  end
end
