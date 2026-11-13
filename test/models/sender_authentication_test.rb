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
end
