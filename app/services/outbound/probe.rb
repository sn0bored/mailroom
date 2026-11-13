module Outbound
  class Probe
    # Built, not created: Send persists it only once the sending rules pass, so a refused probe
    # leaves no draft behind in the owner's Drafts list.
    def self.call(domain, actor: nil)
      raise Send::NotAllowed, "no sender configured" if Mailroom.forward_sender.blank?

      record = OutboundMessage.new(kind: "probe", status: "draft",
        from_address: Mailroom.forward_sender, to_addresses: [ domain.probe_address ],
        subject: "Mailroom probe for #{domain.name}",
        text_body: "This message proves that the domain's forwarder works. It can be ignored.")
      Send.call(record, actor: actor)
    end
  end
end
