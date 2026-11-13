require "test_helper"

class OutboundMailerTest < ActiveSupport::TestCase
  UUID_AT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}@/

  def outbound(kind, to)
    OutboundMessage.create!(kind: kind, status: "queued", from_address: "Owner <owner@example.org>",
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

  # The Mail gem's own default is <random@hostname.mail>, which told every recipient the server's name.
  test "no outbound Message-ID names this machine" do
    ENV["MAILROOM_FORWARD_SENDER"] = "Mailroom <mailroom@example.org>"
    domain = Domain.create!(name: "example.org", forward_copy_to: "owner@example.net")
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(file_fixture("forwarded_sample.eml").read)
    record = Message.create!(domain: domain, inbound_email: inbound, to_address: "hello@example.org",
      from_address: "alice@sender.example.net", subject: "Original", body_text: "Body", received_at: Time.current)
    user = User.create!(email_address: "owner@example.com", password: "test-password")
    mails = %w[reply api probe forward_copy].map { |kind| OutboundMailer.compose(outbound(kind, "someone@example.net")).message }
    mails << ForwardMailer.copy(record).message << PasswordsMailer.reset(user).message

    host = Socket.gethostname.downcase
    mails.each do |mail|
      mail.encoded # what delivery does; Mail fills in its hostname default here if nothing was set
      id = mail.message_id.to_s
      domain_part = id.split("@").last
      assert_match UUID_AT, id
      assert_equal Array(mail.from).first.split("@").last, domain_part, "#{id} uses the From domain"
      assert_not_includes id.downcase, host
      assert_not_includes id.downcase, host.split(".").first
      assert_not id.end_with?(".mail")
    end
  ensure
    ENV.delete("MAILROOM_FORWARD_SENDER")
  end
end
