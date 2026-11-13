require "test_helper"
require_relative "../support/outbound_stubs"

# The forward copy is sent from the owner's own domain, so it must not pass a stranger's mail off as
# something that domain vouches for.
class ForwardMailerTest < ActiveSupport::TestCase
  using OutboundStubs

  PHISHING_HTML = '<html><head><meta http-equiv="refresh" content="0;url=https://evil.example.net/"></head><body>' \
    '<script>alert(1)</script><img src="https://track.example.net/p.gif?u=owner">' \
    '<form action="https://evil.example.net/login"><input name="password"></form>' \
    '<p style="color:red;background:url(https://css.example.net/t.gif)">Your account is locked. ' \
    '<a href="https://evil.example.net/unlock">Unlock it</a></p></body></html>'.freeze
  SPOOFED = "X-Mailroom-Received-SPF: Fail (sender not authorized) identity=mailfrom; client-ip=192.0.2.66; " \
    "envelope-from=service@payments.example.com\nX-Mailroom-Spam-Tests: SPF_FAIL\n".freeze
  AUTHENTIC = "X-Mailroom-Received-SPF: Pass (sender SPF authorized) identity=mailfrom; client-ip=192.0.2.10; " \
    "envelope-from=bounce@mail.payments.example.com\nX-Mailroom-Spam-Tests: DKIM_SIGNED,DKIM_VALID,DKIM_VALID_AU,SPF_PASS\n".freeze

  setup do
    @domain = Domain.create!(name: "example.org", forward_copy_to: "owner@example.net")
    ENV["MAILROOM_FORWARD_SENDER"] = "mailroom@example.org"
  end

  teardown do
    ENV.delete("MAILROOM_FORWARD_SENDER")
    ENV.delete("MAILROOM_TRUSTED_AUTHSERV_IDS")
    ENV.delete("MAILROOM_TRUSTED_FORWARDER_HOSTS")
  end

  def receive(provider_headers: "", from: "Payment Provider <service@payments.example.com>", html: PHISHING_HTML)
    receive_source(<<~EML)
      X-Original-To: hello@example.org
      #{provider_headers}From: #{from}
      To: hello@example.org
      Subject: Account locked
      Message-ID: <#{SecureRandom.hex(6)}@evil.example.net>
      Date: Fri, 13 Nov 2026 09:00:00 +0000
      MIME-Version: 1.0
      Content-Type: text/html; charset=UTF-8

      #{html}
    EML
  end

  def copy_of(message) = ForwardMailer.copy(message).message

  test "forwarded phishing HTML loses script, form and remote images and gains a banner naming the sender" do
    copy = copy_of(receive(provider_headers: SPOOFED))
    html = copy.html_part.decoded

    assert_no_match(/<script|alert\(1\)|<form|<input|<meta|<img|track\.example\.net\/p\.gif|url\(/i, html)
    assert_includes html, "[remote image removed: track.example.net]"
    assert_includes html, '<a href="https://evil.example.net/unlock">Unlock it</a>', "links stay"
    assert_includes html, "Your account is locked."
    banner = html[/\A<div[^>]*>.*?<\/div>/m]
    assert banner, "the banner comes first"
    assert_includes banner, "Forwarded by Mailroom"
    assert_includes banner, "From: &quot;Payment Provider&quot; &lt;service@payments.example.com&gt;"
    assert_includes banner, "To: hello@example.org"
    assert_includes banner, "Date: 2026-11-13 09:00:00 UTC"
    assert_includes banner, "Sender check: unverified for payments.example.com (DMARC fail, SPF fail, DKIM none)"
    text = copy.text_part.decoded
    assert text.start_with?('From: "Payment Provider"')
    assert_includes text, "To: hello@example.org\nDate: 2026-11-13 09:00:00 UTC"
    assert_includes text, "From: \"Payment Provider\" <service@payments.example.com>\nTo: hello@example.org\nDate: 2026-11-13 09:00:00 UTC\nSender check: unverified"
  end

  test "the banner escapes a sender's display name" do
    html = copy_of(receive(from: '"<b>Bank</b>" <service@payments.example.com>')).html_part.decoded
    assert_includes html, "From: &quot;&lt;b&gt;Bank&lt;/b&gt;&quot; &lt;service@payments.example.com&gt;"
    assert_no_match(/<b>Bank/, html)
  end

  test "a DMARC fail tags the subject and a pass does not" do
    assert_equal "[unverified sender] [example.org] Account locked", copy_of(receive(provider_headers: SPOOFED)).subject
    passed = copy_of(receive(provider_headers: AUTHENTIC))
    assert_equal "[example.org] Account locked", passed.subject
    assert_includes passed.html_part.decoded, "Sender check: verified for payments.example.com (DMARC pass, SPF pass, DKIM pass)"
  end

  test "legitimate forwarded mail is unknown, not tagged, when only the forwarder's SPF is known" do
    forwarded = "X-Mailroom-Received-SPF: Pass (sender SPF authorized) identity=mailfrom; client-ip=192.0.2.30; " \
      "envelope-from=SRS0=Ab1c=XY=payments.example.com=service@forwarder.example.net\n" \
      "X-Mailroom-Spam-Tests: DKIM_SIGNED,DKIM_VALID,SPF_PASS\n"
    copy = copy_of(receive(provider_headers: forwarded))
    assert_equal "[example.org] Account locked", copy.subject
    assert_includes copy.html_part.decoded, "Sender check: unknown for payments.example.com (DMARC none, SPF none, DKIM none)"
  end

  test "a trusted forwarder's verdict decides the tag" do
    ENV["MAILROOM_TRUSTED_AUTHSERV_IDS"] = "mx.forwarder.example.net"
    ENV["MAILROOM_TRUSTED_FORWARDER_HOSTS"] = "forwarder.example.net"
    forwarder_spf = "X-Mailroom-Received-SPF: Pass identity=mailfrom; envelope-from=service@forwarder.example.net\n"
    relay = ->(verdict) { "#{forwarder_spf}Received: from out.forwarder.example.net by inbound.postmarkapp.com\n" \
      "Authentication-Results: mx.forwarder.example.net; #{verdict} header.from=payments.example.com\n" }
    assert_equal "[example.org] Account locked", copy_of(receive(provider_headers: relay.("dkim=pass; spf=pass; dmarc=pass"))).subject
    assert_equal "[unverified sender] [example.org] Account locked",
      copy_of(receive(provider_headers: relay.("dkim=none; spf=fail; dmarc=fail"))).subject
  end

  test "no provider signals means no verdict line and no tag" do
    copy = copy_of(receive)
    assert_equal "[example.org] Account locked", copy.subject
    assert_not_includes copy.html_part.decoded, "Sender check"
    assert_not_includes copy.text_part.decoded, "Sender check"
  end

  test "a forged Authentication-Results below the provider's one is ignored" do
    ENV["MAILROOM_TRUSTED_AUTHSERV_IDS"] = "mx.mailhost.example.net"
    ENV["MAILROOM_TRUSTED_FORWARDER_HOSTS"] = "mailhost.example.net"
    headers = "X-Mailroom-Spam-Tests: none\nReceived: from out.mailhost.example.net by inbound.postmarkapp.com\n" \
      "Authentication-Results: mx.mailhost.example.net; dkim=none; spf=softfail smtp.mailfrom=payments.example.com; " \
      "dmarc=fail header.from=payments.example.com\n" \
      "Authentication-Results: mx.mailhost.example.net; dkim=pass; spf=pass; dmarc=pass\n"
    copy = copy_of(receive(provider_headers: headers))
    assert_equal "[unverified sender] [example.org] Account locked", copy.subject
    assert_includes copy.text_part.decoded, "Sender check: unverified for payments.example.com (DMARC fail, SPF softfail, DKIM none)"
  end

  test "an Authentication-Results from an authserv-id nobody trusts does not lift the tag" do
    forged = "Authentication-Results: #{Mailroom::POSTMARK_INBOUND_DOMAIN}; dkim=pass; spf=pass; dmarc=pass\n"
    assert_equal "[unverified sender] [example.org] Account locked", copy_of(receive(provider_headers: forged + SPOOFED)).subject
  end

  test "when sanitizing fails the copy goes out as text only" do
    message = receive(provider_headers: SPOOFED)
    ForwardHtmlScrubber.stub(:new, -> { raise ArgumentError }) do
      copy = copy_of(message)
      assert_nil copy.html_part
      assert_equal "text/plain", copy.mime_type
      assert_includes copy.body.decoded, "From: \"Payment Provider\" <service@payments.example.com>"
    end
  end

  test "negative margins cannot slide the original over the banner" do
    html = copy_of(receive(html: '<p style="margin:-500px 0 0 0;color:#333">hidden banner?</p>')).html_part.decoded
    assert_no_match(/-500px/, html)
    assert_includes html, '<p style="color:#333;">hidden banner?</p>'
  end

  test "the original overlay is contained after the first visible banner" do
    original = '<div style="display:inline-block;margin-top:calc(0px - (300px));background:white">Sender check: verified</div>'
    html = Nokogiri::HTML5.fragment(copy_of(receive(html: original)).html_part.decoded)
    banner, container = html.element_children
    assert_includes banner.text, "Forwarded by Mailroom"
    assert_equal "overflow:hidden;position:relative", container["style"]
    assert_equal "div", container.name
    assert_no_match(/inline-block|calc\(/, container.to_html)
    assert_includes container.text, "Sender check: verified"
  end


  def deceptive_provenance_blocks
    # Include raw duplicates to exercise the banner independently of the sender-check parser.
    raw_signals = AUTHENTIC.gsub("X-Mailroom-Received-SPF:", "Received-SPF:").gsub("X-Mailroom-Spam-Tests:", "X-Spam-Tests:")
    message = receive(provider_headers: AUTHENTIC + raw_signals)
    message.update!(from_name: "security@bank.test\u202E", from_address: "x@evil.test",
      to_address: "hello\u200B@example.org")
    copy = copy_of(message)
    [ Nokogiri::HTML5.fragment(copy.html_part.decoded).element_children.first.text,
      copy.text_part.decoded.split("\n\n", 2).first ]
  end

  test "both provenance blocks quote a display name that looks like an address" do
    deceptive_provenance_blocks.each do |block|
      assert_includes block, 'From: "security@bank.test" <x@evil.test>'
    end
  end

  test "both provenance blocks strip bidi and format characters from every field" do
    deceptive_provenance_blocks.each do |block|
      assert_no_match(/\p{Cf}/, block)
      assert_includes block, "hello@example.org"
    end
  end

  test "both provenance blocks name the domain that the verdict applies to" do
    deceptive_provenance_blocks.each do |block|
      assert_includes block, "Sender check: verified for evil.test"
    end
  end
end
