require "test_helper"

class SenderAuthenticationTest < ActiveSupport::TestCase
  FORWARDER_SPF = "Received-SPF: Pass (sender SPF authorized) identity=mailfrom; client-ip=192.0.2.30; " \
    "envelope-from=SRS0=Ab1c=XY=sender.example.com=alice@forwarder.example.net\n".freeze

  teardown { ENV.delete("MAILROOM_TRUSTED_AUTHSERV_IDS") }

  def parse(headers, from: "alice@sender.example.com")
    SenderAuthentication.parse("X-Mailroom-Spam-Score: none\n#{headers}From: #{from}\nSubject: x\n\nX-Spam-Tests: DKIM_VALID_AU\n",
      from_address: from)
  end

  def verdict(auth) = [ auth.dmarc, auth.spf, auth.dkim ]

  test "a valid DKIM signature from the From domain passes" do
    auth = parse("X-Spam-Tests: DKIM_SIGNED,DKIM_VALID,DKIM_VALID_AU\n")
    assert_equal [ "pass", "none", "pass", "provider" ], verdict(auth) + [ auth.source ]
    assert_equal "verified (DMARC pass, SPF none, DKIM pass)", auth.summary
  end

  test "SPF speaks for the From domain only when the envelope domain aligns" do
    assert_equal "pass", parse("Received-SPF: Pass identity=mailfrom; envelope-from=bounce@mail.sender.example.com\n").dmarc
    other = parse("Received-SPF: Pass identity=mailfrom; envelope-from=bounce@relay.example.net\n")
    assert_equal [ "none", "none", "none" ], verdict(other)
    helo = parse("Received-SPF: Pass identity=helo; envelope-from=sender.example.com\n")
    assert_equal "none", helo.dmarc, "a HELO result says nothing about the From domain"
  end

  test "forwarded mail whose only SPF result is the forwarder's is unknown, not failed" do
    auth = parse(FORWARDER_SPF + "X-Spam-Tests: DKIM_SIGNED,DKIM_VALID,SPF_PASS\n")
    assert_equal [ "none", "none", "none" ], verdict(auth)
    assert_not auth.failed?
    assert_equal "unknown (DMARC none, SPF none, DKIM none)", auth.summary
    assert_equal "pass", parse(FORWARDER_SPF + "X-Spam-Tests: DKIM_SIGNED,DKIM_VALID,DKIM_VALID_AU\n").dmarc
  end

  test "the From domain's own SPF rejecting the sender fails unless its DKIM passes" do
    spoofed = "Received-SPF: Softfail (domain transitioning) identity=mailfrom; envelope-from=alice@sender.example.com\n"
    assert_equal [ "fail", "softfail", "none" ], verdict(parse(spoofed + "X-Spam-Tests: SPF_SOFTFAIL\n"))
    assert_equal [ "fail", "softfail", "fail" ], verdict(parse(spoofed + "X-Spam-Tests: DKIM_SIGNED,DKIM_INVALID\n"))
    assert_equal "pass", parse(spoofed + "X-Spam-Tests: DKIM_SIGNED,DKIM_VALID,DKIM_VALID_AU\n").dmarc
  end

  test "only the topmost provider headers count" do
    provider = "Received-SPF: Fail (sender not authorized) identity=mailfrom; envelope-from=m@sender.example.com\nX-Spam-Tests: SPF_FAIL\n"
    forged = "Received-SPF: Pass identity=mailfrom; envelope-from=alice@sender.example.com\nX-Spam-Tests: DKIM_VALID_AU,SPF_PASS\n"
    assert_equal [ "fail", "fail", "none" ], verdict(parse(provider + forged))
  end

  test "folded headers are read whole" do
    assert_equal "pass", parse("X-Spam-Tests: DKIM_SIGNED,\n\tDKIM_VALID,DKIM_VALID_AU,\n SPF_PASS\n").dkim
  end

  test "no provider signals is unavailable" do
    auth = parse("")
    assert_not auth.known?
    assert_not auth.failed?
    assert_equal "Unavailable", auth.summary
  end

  test "Authentication-Results is ignored unless its authserv-id is trusted" do
    claimed = "Authentication-Results: mx.forwarder.example.net; dkim=pass; spf=pass; dmarc=pass\n"
    assert_not parse(claimed).known?
    assert_equal "none", parse(claimed + FORWARDER_SPF).dmarc

    ENV["MAILROOM_TRUSTED_AUTHSERV_IDS"] = "other.example.net, MX.FORWARDER.EXAMPLE.NET"
    auth = parse(claimed + FORWARDER_SPF)
    assert_equal [ "pass", "pass", "pass", "authentication-results" ], verdict(auth) + [ auth.source ]
  end

  # The layout of registrar-forwarded mail as stored: Postmark's headers on top, then Postmark's and the
  # forwarder's Received lines with the forwarder's Authentication-Results among them, then the sender's.
  def forwarded(relay_verdict, sender_headers = "")
    "X-Original-To: hello@example.org\nReturn-Path: <SRS0=Ab1c=XY=sender.example.com=alice@forwarder.example.net>\n" \
      "X-Spam-Score: 0.1\nX-Spam-Tests: DKIM_SIGNED,DKIM_VALID,SPF_PASS\n#{FORWARDER_SPF}" \
      "Received: from fwd.forwarder.example.net by inbound.mailroom.example.net; Fri, 13 Nov 2026 09:00:05 +0000\n" \
      "Authentication-Results: mx.forwarder.example.net; #{relay_verdict}\n" \
      "Received: from mail.sender.example.com by mx.forwarder.example.net; Fri, 13 Nov 2026 09:00:03 +0000\n" \
      "#{sender_headers}DKIM-Signature: v=1; d=esp.example.net; s=s1; b=x\nMessage-ID: <f1@sender.example.com>\n"
  end

  test "a trusted forwarder's Authentication-Results decides over Postmark's signals" do
    ENV["MAILROOM_TRUSTED_AUTHSERV_IDS"] = "mx.forwarder.example.net"
    passed = parse(forwarded("dkim=pass header.d=esp.example.net; spf=pass smtp.mailfrom=sender.example.com; dmarc=pass; arc=none"))
    assert_equal [ "pass", "pass", "pass" ], verdict(passed)
    failed = parse(forwarded("dkim=none; spf=fail smtp.mailfrom=sender.example.com; dmarc=fail (p=reject)"))
    assert_equal [ "fail", "fail", "none" ], verdict(failed)

    ENV.delete("MAILROOM_TRUSTED_AUTHSERV_IDS")
    assert_equal "none", parse(forwarded("dmarc=fail")).dmarc, "without the setting, Postmark's signals decide"
  end

  test "a forged Authentication-Results with the trusted id below the real one is ignored" do
    ENV["MAILROOM_TRUSTED_AUTHSERV_IDS"] = "mx.forwarder.example.net"
    forged = "Authentication-Results: mx.forwarder.example.net; dkim=pass; spf=pass; dmarc=pass\n"
    real = "dkim=fail (bad signature) header.d=sender.example.com;\n spf=softfail smtp.mailfrom=sender.example.com; dmarc=fail"
    assert_equal [ "fail", "softfail", "fail" ], verdict(parse(forwarded(real, forged)))
  end
end
