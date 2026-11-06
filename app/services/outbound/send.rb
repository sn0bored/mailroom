module Outbound
  # Delivers an OutboundMessage through the configured mailer. Implemented in the outbound chunk;
  # this stub only fixes the interface the UI and API call.
  class Send
    class NotAllowed < StandardError; end

    def self.call(outbound_message, actor: nil)
      new(outbound_message, actor: actor).call
    end

    def initialize(outbound_message, actor: nil)
      @outbound_message = outbound_message
      @actor = actor
    end

    def call
      raise NotImplementedError, "Outbound::Send is implemented in the outbound chunk"
    end
  end
end
