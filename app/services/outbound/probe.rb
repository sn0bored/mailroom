module Outbound
  # Sends probe-<token>@domain through the configured sender so the owner can prove a domain receives.
  # Implemented in the outbound chunk; this stub fixes the interface the UI calls.
  class Probe
    def self.call(domain, actor: nil)
      raise NotImplementedError, "Outbound::Probe is implemented in the outbound chunk"
    end
  end
end
