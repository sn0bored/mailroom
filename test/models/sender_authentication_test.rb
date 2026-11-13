require "test_helper"

class SenderAuthenticationTest < ActiveSupport::TestCase
  teardown { ENV.delete("MAILROOM_TRUSTED_AUTHSERV_IDS") }

  def parse(headers, from: "alice@sender.example.com")
    SenderAuthentication.parse("X-Mailroom-Spam-Score: none\n#{headers}From: #{from}\nSubject: x\n\nX-Spam-Tests: DKIM_VALID_AU\n",
      from_address: from)
  end

  test "a valid DKIM signature from the From domain passes" do
    auth = parse("X-Spam-Tests: DKIM_SIGNED,DKIM_VALID,DKIM_VALID_AU\n")
    assert_equal [ "pass", "none", "pass", "provider" ], [ auth.dmarc, auth.spf, auth.dkim, auth.source ]
    assert_equal "verified (DMARC pass, SPF none, DKIM pass)", auth.summary
  end

  test "an SPF pass counts only when the envelope domain aligns with From" do
    aligned = "Received-SPF: Pass (sender SPF authorized) identity=mailfrom; envelope-from=bounce@mail.sender.example.com\n"
    assert_equal "pass", parse(aligned).dmarc
    elsewhere = "Received-SPF: Pass (sender SPF authorized) identity=mailfrom; envelope-from=bounce@relay.example.net\n"
    auth = parse(elsewhere)
    assert_equal [ "fail", "pass" ], [ auth.dmarc, auth.spf ]
    assert auth.failed?
    helo = "Received-SPF: Pass identity=helo; envelope-from=sender.example.com\n"
    assert_equal "fail", parse(helo).dmarc, "a HELO pass says nothing about the From domain"
  end

  test "only the topmost provider headers count" do
    provider = "Received-SPF: Fail (sender not authorized) identity=mailfrom; envelope-from=m@evil.example.net\nX-Spam-Tests: SPF_FAIL\n"
    forged = "Received-SPF: Pass identity=mailfrom; envelope-from=alice@sender.example.com\nX-Spam-Tests: DKIM_VALID_AU,SPF_PASS\n"
    auth = parse(provider + forged)
    assert_equal [ "fail", "fail", "none" ], [ auth.dmarc, auth.spf, auth.dkim ]
  end

  test "folded headers are read whole" do
    assert_equal "pass", parse("X-Spam-Tests: DKIM_SIGNED,\n\tDKIM_VALID,DKIM_VALID_AU,\n SPF_PASS\n").dkim
  end

  test "no provider signals is unknown" do
    auth = parse("")
    assert_not auth.known?
    assert_not auth.failed?
    assert_equal "Unavailable", auth.summary
  end

  test "Authentication-Results is ignored unless its authserv-id is trusted" do
    claimed = "Authentication-Results: mx.mailhost.example.net; dkim=pass; spf=pass; dmarc=pass\n"
    assert_not parse(claimed).known?
    assert_equal "fail", parse(claimed + "X-Spam-Tests: SPF_FAIL\n").dmarc

    ENV["MAILROOM_TRUSTED_AUTHSERV_IDS"] = "other.example.net, MX.MAILHOST.EXAMPLE.NET"
    auth = parse(claimed + "X-Spam-Tests: SPF_FAIL\n")
    assert_equal [ "pass", "pass", "pass", "authentication-results" ], [ auth.dmarc, auth.spf, auth.dkim, auth.source ]
  end

  test "the topmost trusted Authentication-Results wins over forged copies below it" do
    ENV["MAILROOM_TRUSTED_AUTHSERV_IDS"] = "mx.mailhost.example.net"
    headers = "Authentication-Results: relay.example.net; dmarc=pass\n" \
      "Authentication-Results: mx.mailhost.example.net 1; dkim=fail (bad signature) header.d=sender.example.com;\n" \
      " spf=softfail smtp.mailfrom=sender.example.com; dmarc=fail (p=reject) header.from=sender.example.com\n" \
      "Authentication-Results: mx.mailhost.example.net; dkim=pass; spf=pass; dmarc=pass\n"
    auth = parse(headers)
    assert_equal [ "fail", "softfail", "fail" ], [ auth.dmarc, auth.spf, auth.dkim ]
  end
end
