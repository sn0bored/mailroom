require "test_helper"

class OutboundMailerTest < ActiveSupport::TestCase
  def outbound(kind, to)
    OutboundMessage.create!(kind: kind, status: "queued", from_address: "owner@example.org",
      to_addresses: [ to ], subject: "Hello", text_body: "Text")
  end

  test "a reply to a stranger carries no loop marker" do
    mail = OutboundMailer.compose(outbound("reply", "stranger@example.net")).message
    assert_nil mail[LoopMarker::HEADER]
    assert_nil mail["X-Mailroom-Instance"]
  end

  test "a probe carries a marker bound to its own Message-ID" do
    mail = OutboundMailer.compose(outbound("probe", "probe-abc@example.org")).message
    assert_match(/@example\.org\z/, mail.message_id)
    marker = mail[LoopMarker::HEADER].value
    assert LoopMarker.valid?(mail.message_id, marker)
    assert_not LoopMarker.valid?("another@example.org", marker)
  end
end
