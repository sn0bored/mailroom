require "test_helper"

class SenderAuthenticationSecurityTest < ActiveSupport::TestCase
  OWNED_NONE = "X-Mailroom-Spam-Tests: none\nX-Mailroom-Received-SPF: none\n".freeze
  PASS = "dkim=pass header.d=bank.test; spf=pass smtp.mailfrom=bank.test; dmarc=pass header.from=bank.test".freeze

  setup do
    ENV["MAILROOM_TRUSTED_AUTHSERV_IDS"] = "mx.forwarder.example.net"
    ENV["MAILROOM_TRUSTED_FORWARDER_HOSTS"] = "forwarder.example.net"
  end

  teardown do
    ENV.delete("MAILROOM_TRUSTED_AUTHSERV_IDS")
    ENV.delete("MAILROOM_TRUSTED_FORWARDER_HOSTS")
  end

  def parse(headers)
    SenderAuthentication.parse("#{headers}From: ceo@bank.test\n\nBody", from_address: "ceo@bank.test")
  end

  def forwarded(result, peer: "out.forwarder.example.net", sender_headers: "")
    OWNED_NONE +
      "Received: from #{peer} by inbound.postmarkapp.com; Fri, 13 Nov 2026 09:00:05 +0000\n" \
      "Received: from #{peer} by mx.postmarkapp.com; Fri, 13 Nov 2026 09:00:04 +0000\n" \
      "Received: from relay.forwarder.example.net by out.forwarder.example.net; Fri, 13 Nov 2026 09:00:03 +0000\n" \
      "Authentication-Results: mx.forwarder.example.net; #{result}\n" \
      "Received: from mail.example.com by relay.forwarder.example.net; Fri, 13 Nov 2026 09:00:02 +0000\n" \
      "Received: from sender.example.com by mail.example.com; Fri, 13 Nov 2026 09:00:01 +0000\n#{sender_headers}"
  end

  [ "X-Spam-Tests: DKIM_SIGNED,DKIM_VALID,DKIM_VALID_AU\n",
    "Received-SPF: pass identity=mailfrom; envelope-from=ceo@bank.test\n" ].each_with_index do |forged, index|
    test "raw provider forgery #{index} cannot verify old or newly ingested mail" do
      assert_equal "none", parse(forged).dmarc
      assert_equal "none", parse(OWNED_NONE + forged).dmarc
    end
  end

  test "only the first owned signals count even when raw signals sit above them" do
    headers = "Received: from mail.example.com by inbound.postmarkapp.com\nX-Spam-Tests: DKIM_VALID_AU\n" + OWNED_NONE +
      "X-Mailroom-Spam-Tests: DKIM_VALID_AU\nX-Mailroom-Received-SPF: pass envelope-from=ceo@bank.test\n"
    assert_equal "none", parse(headers).dmarc
  end

  test "owned provider signals work below the sender MTA Received line" do
    auth = parse("Received: from sender.example.com by mx.example.net\nX-Mailroom-Spam-Tests: DKIM_VALID_AU\n")
    assert_equal "pass", auth.dmarc
  end

  test "a realistic forwarder chain keeps its aligned verdict" do
    auth = parse(forwarded(PASS))
    assert_equal [ "pass", "pass", "pass", "authentication-results" ], [ auth.dmarc, auth.spf, auth.dkim, auth.source ]
  end

  test "legacy messages without owned signals cannot be verified through Authentication Results" do
    assert_equal "none", parse(forwarded(PASS).delete_prefix(OWNED_NONE)).dmarc
  end

  {
    quoted: 'spf=pass smtp.mailfrom="x;dmarc=pass"@evil.test; dkim=none; dmarc=fail header.from=bank.test',
    comment: "spf=pass (outer (nested);dmarc=pass); dkim=none; dmarc=fail header.from=bank.test",
    escaped_quote: 'spf=pass smtp.mailfrom="x\";dmarc=pass"@evil.test; dmarc=fail header.from=bank.test'
  }.each do |name, result|
    test "#{name} cannot inject a method result" do
      assert_equal "fail", parse(forwarded(result)).dmarc
    end
  end

  test "DMARC requires the stored From domain" do
    [ "dmarc=pass header.from=evil.test", "dmarc=pass", 'dmarc=pass reason="header.from=bank.test" header.from=evil.test' ].each do |result|
      assert_equal "none", parse(forwarded(result)).dmarc, result
    end
    assert_equal "pass", parse(forwarded('dmarc=pass header.from="BANK.TEST"')).dmarc
  end

  test "DKIM requires an aligned signing domain or identity" do
    [ "header.d=evil.test", "header.i=@evil.test", "header.d=bank.test header.i=@evil.test", "" ].each do |property|
      assert_equal "none", parse(forwarded("dkim=pass #{property}; dmarc=none")).dkim, property
    end
    [ "header.d=BANK.TEST", 'header.i="sender@BANK.TEST"' ].each do |property|
      assert_equal "pass", parse(forwarded("dkim=pass #{property}")).dkim
    end
  end

  test "direct and MX deliveries cannot claim a trusted forwarder verdict" do
    [ "mail.evil.test", "forwarder.example.net.evil.test", "notforwarder.example.net" ].each do |peer|
      assert_equal "none", parse(forwarded(PASS, peer: peer)).dmarc, peer
    end
    assert_equal "none", parse(OWNED_NONE + "Authentication-Results: mx.forwarder.example.net; #{PASS}\n").dmarc
  end

  test "a forged Postmark hop below a sender hop cannot establish trust" do
    headers = OWNED_NONE + "Received: from mail.evil.test by mx.example.org\n" + forwarded(PASS)
    assert_equal "none", parse(headers).dmarc
    assert_equal "none", parse(forwarded(PASS).gsub("by inbound.postmarkapp.com", "by inbound.postmarkapp.com.evil.test")).dmarc
  end

  test "an Authentication Results below an untrusted Received is ignored" do
    forgery = "Authentication-Results: mx.forwarder.example.net; #{PASS}\n"
    headers = forwarded("none", sender_headers: forgery).sub("Authentication-Results: mx.forwarder.example.net; none\n", "")
    assert_equal "none", parse(headers).dmarc
  end

  test "direct delivery falls back to owned signals" do
    headers = forwarded("dmarc=fail header.from=bank.test", peer: "mail.example.com")
      .sub("X-Mailroom-Spam-Tests: none", "X-Mailroom-Spam-Tests: DKIM_VALID_AU")
    assert_equal "pass", parse(headers).dmarc
    assert_equal "provider", parse(headers).source
  end

  test "comments in the authserv id and Received hop do not change token boundaries" do
    headers = forwarded(PASS).sub("mx.forwarder.example.net;", "mx.forwarder.example.net (nested (comment); text);")
      .sub("from out.forwarder.example.net by", "from OUT.FORWARDER.EXAMPLE.NET (out.forwarder.example.net [192.0.2.1]) by")
    assert_equal "pass", parse(headers).dmarc
  end

  test "unclosed quotes and comments cannot expose forged method results" do
    [ 'spf=pass reason="oops; dmarc=pass header.from=bank.test',
      "spf=pass (oops; dmarc=pass header.from=bank.test" ].each do |result|
      assert_equal "none", parse(forwarded(result)).dmarc
    end
  end

  test "a trusted authserv id still requires configured forwarder hosts" do
    ENV.delete("MAILROOM_TRUSTED_FORWARDER_HOSTS")
    assert_equal "provider", parse(forwarded(PASS)).source
    assert_equal "none", parse(forwarded(PASS)).dmarc
  end
end
