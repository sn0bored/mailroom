require "test_helper"

class DraftReplyTest < ActiveSupport::TestCase
  setup do
    Domain.create!(name: "example.org")
    @key, = create_api_key(scopes: %w[mail:read mail:draft])
  end

  def receive(to: "hello@example.org", cc: nil, reply_to: nil)
    mail = Mail.new
    mail.from = "Mallory <mallory@example.net>"
    mail.to = to
    mail.cc = cc if cc
    mail.reply_to = reply_to if reply_to
    mail.subject = "Quick question"
    mail.message_id = "<#{SecureRandom.hex(6)}@example.net>"
    mail.body = "Can you confirm the wire details?"
    receive_source("X-Original-To: hello@example.org\n" + mail.to_s)
  end

  def draft_reply(message, reply_all: true)
    result = Mcp::Tools::DraftReply.call({ id: message.id, text_body: "Confirmed.", reply_all: reply_all }, @key)
    [ OutboundMessage.find(result.dig(:structuredContent, :draft_id)), result, result[:content].first[:text] ]
  end

  test "reply-all keeps the sender and owned-domain recipients and reports the outsiders it left off" do
    message = receive(to: "hello@example.org, colleague@example.org",
      cc: "journalist@example.com, competitor@example.net", reply_to: "harvest@example.com")
    draft, result, text = draft_reply(message)

    assert_equal [ "harvest@example.com" ], draft.to_addresses
    assert_equal %w[colleague@example.org mallory@example.net], draft.cc_addresses.sort
    outgoing = OutboundMailer.compose(draft)
    assert_equal %w[colleague@example.org mallory@example.net], outgoing.cc.sort
    assert_not_includes outgoing.destinations, "journalist@example.com"
    assert_not_includes outgoing.destinations, "competitor@example.net"

    assert_includes text, "Reply-all left off 2 recipient(s)"
    # The frame may prefix each line of email text (e.g. "│ "); the addresses stay inside the block either way.
    assert_match(/UNTRUSTED_EMAIL nonce=\h+ left_off_recipients message_id=#{message.id}>>>\n(?:│ )?journalist@example.com\n(?:│ )?competitor@example.net\n/, text)
    assert_includes text, "Reply-To address, which differs from its sender"
    assert_equal 2, result.dig(:structuredContent, :left_off_recipients)
  end

  test "reply-all without outsiders reports nothing left off" do
    draft, result, text = draft_reply(receive(to: "hello@example.org, colleague@example.org"))
    assert_equal [ "mallory@example.net" ], draft.to_addresses
    assert_equal [ "colleague@example.org" ], draft.cc_addresses
    assert_not_includes text, "left off"
    assert_not_includes text, "Reply-To"
    assert_equal 0, result.dig(:structuredContent, :left_off_recipients)
  end

  test "a plain reply copies nobody" do
    draft, = draft_reply(receive(cc: "journalist@example.com, colleague@example.org"), reply_all: false)
    assert_equal [ "mallory@example.net" ], draft.to_addresses
    assert_empty draft.cc_addresses
  end
end
