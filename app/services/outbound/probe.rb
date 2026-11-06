module Outbound
  class Probe
    def self.call(domain, actor: nil)
      raise Send::NotAllowed, "no sender configured" if Mailroom.forward_sender.blank?

      record = OutboundMessage.create!(kind: "probe", status: "draft",
        from_address: Mailroom.forward_sender, to_addresses: [domain.probe_address],
        subject: "Mailroom probe for #{domain.name}",
        text_body: "This message proves that the domain's forwarder works. It can be ignored.")
      Send.call(record, actor: actor)
    end
  end
end
