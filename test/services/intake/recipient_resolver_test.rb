require "test_helper"

class Intake::RecipientResolverTest < ActiveSupport::TestCase
  test "forwarded mail routes by the registrar's X-Original-To, ignoring the provider hash the ingress prepends" do
    raw = "X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source
    result = Intake::RecipientResolver.call(Mail.new(raw), owned_names: %w[example.org])
    assert_equal "hello@example.org", result.primary
    assert_equal "hdr:X-Original-To", result.routed_via
    assert_equal [ "hello@example.org" ], result.matches
    assert_includes result.trace, { "header" => "X-Original-To", "address" => "abc123hash@inbound.postmarkapp.com" }
    assert_includes result.trace, { "header" => "Received", "address" => "hello@example.org" }
  end

  test "mx mode routes by the X-Original-To the ingress writes" do
    raw = "X-Original-To: support@mail.example.org\n" + mx_source
    result = Intake::RecipientResolver.call(Mail.new(raw), owned_names: %w[mail.example.org])
    assert_equal "support@mail.example.org", result.primary
    assert_equal "hdr:X-Original-To", result.routed_via
  end

  test "falls back to To/Cc when no envelope header matches" do
    mail = Mail.new("From: a@sender.example.net\nTo: Someone <team@example.org>\nCc: other@example.net\nSubject: x\n\nbody")
    result = Intake::RecipientResolver.call(mail, owned_names: %w[example.org])
    assert_equal "team@example.org", result.primary
    assert_equal "to:To", result.routed_via
  end

  test "unrouted when nothing matches an owned domain" do
    result = Intake::RecipientResolver.call(Mail.new(forwarded_source), owned_names: %w[other.example])
    assert result.unrouted?
    assert_equal "unrouted", result.routed_via
    assert_equal [], result.matches
    assert result.trace.any?
  end

  test "keeps plus tags and lowercases" do
    mail = Mail.new("Delivered-To: Hello+Tag@Example.ORG\nTo: x@example.org\nSubject: x\n\nbody")
    result = Intake::RecipientResolver.call(mail, owned_names: %w[example.org])
    assert_equal "hello+tag@example.org", result.primary
    assert_equal %w[hello+tag@example.org x@example.org], result.matches
  end

  # A domain with a hosted catch-all mailbox that auto-forwards here. The fixture is a Sieve redirect
  # from a Postfix/Dovecot host; the ingress prepends the Postmark hash as X-Original-To.
  HASH = "X-Original-To: abc123hash@inbound.postmarkapp.com\n".freeze
  MX_FOR = "\tfor <careers@example.org>; Fri, 13 Nov 2026 09:00:03 +0000 (UTC)"

  def resolve_hosted(source = hosted_source, owned: %w[example.org], mailboxes: %w[info@example.org])
    Intake::RecipientResolver.call(Mail.new(HASH + source), owned_names: owned, catch_all_mailboxes: mailboxes)
  end

  def without_mx_for(source = hosted_source)
    source.sub(MX_FOR, "\tFri, 13 Nov 2026 09:00:03 +0000 (UTC)").tap { |s| assert_not_equal source, s }
  end

  test "without a catch-all mailbox the hosted mailbox wins, as before" do
    result = resolve_hosted(mailboxes: [])
    assert_equal "info@example.org", result.primary
    assert_equal "hdr:Delivered-To", result.routed_via
    assert_not result.trace.any? { |t| t["header"] == "catch_all_mailbox" }
  end

  test "a catch-all mailbox is looked past to the recipient on the host's MX hop" do
    result = resolve_hosted
    assert_equal "careers@example.org", result.primary
    assert_equal "catch-all:Received", result.routed_via
    assert_equal %w[info@example.org careers@example.org], result.matches
    assert_includes result.trace, { "header" => "catch_all_mailbox", "address" => "info@example.org" }
    assert_includes result.trace, { "header" => "X-Original-To", "address" => "abc123hash@inbound.postmarkapp.com" }
  end

  test "the mailbox setting and the headers are compared ignoring case" do
    source = hosted_source.sub("Delivered-To: info@example.org", "Delivered-To: <INFO@Example.ORG>")
                          .sub("for <careers@example.org>", "for <Careers@EXAMPLE.org>")
    result = resolve_hosted(source, owned: %w[Example.ORG], mailboxes: %w[Info@Example.org])
    assert_equal "careers@example.org", result.primary
  end

  test "mail addressed to the mailbox itself stays with it" do
    source = hosted_source.sub("for <careers@example.org>", "for <info@example.org>")
                          .sub("To: Careers Team <careers@example.org>", "To: Info <info@example.org>")
    result = resolve_hosted(source)
    assert_equal "info@example.org", result.primary
    assert_equal "hdr:Delivered-To", result.routed_via
    assert_includes result.trace, { "header" => "catch_all_mailbox", "address" => "info@example.org" }
  end

  test "mail visibly addressed to the mailbox first keeps it even with another address in Cc" do
    source = without_mx_for.sub("To: Careers Team <careers@example.org>", "To: info@example.org")
                           .sub("Cc: Hiring Partner <partner@example.net>", "Cc: careers@example.org")
    assert_equal "info@example.org", resolve_hosted(source).primary
  end

  test "bcc mail resolves through the Received hop alone" do
    source = hosted_source.sub("To: Careers Team <careers@example.org>", "To: Undisclosed recipients:;")
                          .sub("Cc: Hiring Partner <partner@example.net>\n", "")
    result = resolve_hosted(source)
    assert_equal "careers@example.org", result.primary
    assert_equal "catch-all:Received", result.routed_via
  end

  test "with several same-domain recipients and no single-recipient hop, the first in To wins" do
    # Postfix leaves out the "for" clause when one transaction carries several recipients.
    to_both = without_mx_for.sub("To: Careers Team <careers@example.org>", "To: Careers <careers@example.org>, \"Press, Desk\" <press@example.org>")
    result = resolve_hosted(to_both)
    assert_equal "careers@example.org", result.primary
    assert_equal "catch-all:To", result.routed_via
    assert_equal %w[info@example.org careers@example.org press@example.org], result.matches

    reversed = without_mx_for.sub("To: Careers Team <careers@example.org>", "To: press@example.org, careers@example.org")
    assert_equal "press@example.org", resolve_hosted(reversed).primary

    in_cc = without_mx_for.sub("To: Careers Team <careers@example.org>", "To: partner@example.net")
                          .sub("Cc: Hiring Partner <partner@example.net>", "Cc: Jobs <jobs@example.org>")
    result = resolve_hosted(in_cc)
    assert_equal "jobs@example.org", result.primary
    assert_equal "catch-all:Cc", result.routed_via
  end

  test "a Received hop naming several recipients counts for nothing" do
    source = hosted_source.sub("for <careers@example.org>", "for <press@example.org>, <jobs@example.org>")
    result = resolve_hosted(source)
    assert_equal "careers@example.org", result.primary
    assert_equal "catch-all:To", result.routed_via
  end

  test "Received hops without a for clause or that do not parse are skipped" do
    source = without_mx_for.sub("Received: from mail.sender.example.net",
      "Received: for\nReceived: ;;; garbage <not an address>\nReceived: from mail.sender.example.net")
    source = source.sub("To: Careers Team <careers@example.org>", "To: hr@example.org")
    result = resolve_hosted(source)
    assert_equal "hr@example.org", result.primary
    assert_equal "catch-all:To", result.routed_via
  end

  test "the trace is read from the top down, so the hop nearest us wins" do
    source = hosted_source.sub("for <info@example.org>;", "for <alias-target@example.org>;")
    assert_equal "alias-target@example.org", resolve_hosted(source).primary
  end

  FORGED = "X-Original-To: ceo@example.org\nDelivered-To: ceo@example.org\n" \
           "Received: from forged.sender.example.net by mx1.mailhost.example.net (Postfix) with ESMTP id FORGED\n" \
           "\tfor <ceo@example.org>; Fri, 13 Nov 2026 08:59:59 +0000 (UTC)\n".freeze

  def with_forged_trace(source)
    marker = "X-Spam-Status: No, score=0.2\n"
    source.sub(marker, FORGED + marker).tap { |s| assert_not_equal source, s }
  end

  test "trace headers the sender wrote below the host's MX hop never beat it" do
    result = resolve_hosted(with_forged_trace(hosted_source))
    assert_equal "careers@example.org", result.primary
    assert_equal "catch-all:Received", result.routed_via
    assert_not_includes result.trace, { "header" => "X-Original-To", "address" => "careers@example.org" }
  end

  test "residual: with no single-recipient MX hop, a header the sender planted can still win on the same domain" do
    # Accepted: no worse than a forged To, and the domain cannot change.
    source = with_forged_trace(without_mx_for).sub("To: Careers Team <careers@example.org>", "To: careers@example.org, press@example.org")
    result = resolve_hosted(source)
    assert_equal "ceo@example.org", result.primary
    assert_equal "catch-all:X-Original-To", result.routed_via
  end

  test "stray 8-bit header bytes do not stop the scan" do
    # Raw mail arrives as bytes; a Latin-1 subject is not valid UTF-8.
    source = hosted_source.b.sub("Subject: Application for the platform role", "Subject: Caf\xE9 application".b)
                           .sub("To: Careers Team <careers@example.org>", "To: partner@example.net")
    assert_not source.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    assert_equal "careers@example.org", resolve_hosted(source).primary
  end

  test "original-recipient headers the host writes at delivery count before its MX hop" do
    { "X-Original-To" => "Postfix", "X-Gm-Original-To" => "Google", "X-Delivered-to" => "Fastmail",
      "Envelope-To" => "Exim" }.each_key do |header|
      source = hosted_source.sub("Delivered-To: info@example.org", "#{header}: <jobs@example.org>\nDelivered-To: info@example.org")
      result = resolve_hosted(source)
      assert_equal "jobs@example.org", result.primary, header
      # X-Original-To and Envelope-To are envelope headers, so the base scan already finds them.
      assert_match(/\A(hdr|catch-all):#{Regexp.escape(header.sub('X-Delivered-to', 'X-Delivered-To'))}\z/, result.routed_via)
      assert_includes result.matches, "jobs@example.org"
    end
  end

  test "an earlier hop's Delivered-To is an original recipient" do
    source = hosted_source.sub("Received: from mx1.mailhost.example.net", "Delivered-To: careers@example.org\nReceived: from mx1.mailhost.example.net")
    result = resolve_hosted(without_mx_for(source))
    assert_equal "careers@example.org", result.primary
    assert_equal "catch-all:Delivered-To", result.routed_via
  end

  test "headers naming the forwarding mailbox or its destination are never the answer" do
    source = without_mx_for.sub("X-Sieve-Redirected-From: info@example.org", "X-Sieve-Redirected-From: admin@example.org\n" \
      "X-Forwarded-For: admin@example.org abc123hash@inbound.postmarkapp.com\nX-Forwarded-To: abc123hash@inbound.postmarkapp.com")
    source = source.sub("To: Careers Team <careers@example.org>", "To: partner@example.net").sub(/^Cc: .*\n/, "")
    result = resolve_hosted(source)
    assert_equal "info@example.org", result.primary
    assert_equal "hdr:Delivered-To", result.routed_via
  end

  test "a To on another owned domain never moves the message off the mailbox's domain" do
    source = without_mx_for.sub("To: Careers Team <careers@example.org>", "To: careers@example.net")
                           .sub(/^Cc: .*\n/, "")
    result = resolve_hosted(source, owned: %w[example.org example.net])
    assert_equal "info@example.org", result.primary
    assert_includes result.matches, "careers@example.net"
  end

  test "a Gmail-style auto-forward resolves through the MX hop, whose for clause carries a comment" do
    source = <<~EML
      Received: from relay.mailhost.example.net (relay.mailhost.example.net. [192.0.2.41])
              by inbound.postmarkapp.com with ESMTPS id gmail0001
              for <abc123hash@inbound.postmarkapp.com>; Fri, 13 Nov 2026 09:10:02 +0000 (UTC)
      X-Forwarded-To: abc123hash@inbound.postmarkapp.com
      X-Forwarded-For: info@example.org abc123hash@inbound.postmarkapp.com
      Delivered-To: info@example.org
      Received: by 2002:a05:6000:1a8b:b0:3f1:1234:5678 with SMTP id abc123;
              Fri, 13 Nov 2026 01:10:01 -0800 (PST)
      Received: from mail.sender.example.net (mail.sender.example.net. [203.0.113.10])
              by mx.mailhost.example.net with ESMTPS id x12si345678
              for <Press@example.org>
              (Google Transport Security);
              Fri, 13 Nov 2026 01:10:01 -0800 (PST)
      From: Alice Example <alice@sender.example.net>
      To: Press <press@example.org>
      Subject: Interview request
      Message-ID: <gmail-0001@sender.example.net>

      body
    EML
    result = resolve_hosted(source)
    assert_equal "press@example.org", result.primary
    assert_equal "catch-all:Received", result.routed_via
  end

  # Envelope headers are read from the top down: a header the sender planted below the hops that
  # received the message can't beat them, so it can't move mail to another owned domain.
  FORGED_DELIVERED_TO = "Delivered-To: boss@example.net\n".freeze

  test "a forged Delivered-To below the registrar's headers does not pick the domain" do
    source = "X-Original-To: abc123hash@inbound.postmarkapp.com\n" +
      forwarded_source.sub("From: Alice Example", FORGED_DELIVERED_TO + "From: Alice Example")
    result = Intake::RecipientResolver.call(Mail.new(source), owned_names: %w[example.org example.net])
    assert_equal "hello@example.org", result.primary
    assert_equal "hdr:X-Original-To", result.routed_via
    assert_includes result.matches, "boss@example.net"
  end

  test "a forged Delivered-To loses to a registrar that writes only Received lines" do
    source = forwarded_source.sub("X-Original-To: <hello@example.org>\n", "")
                             .sub("From: Alice Example", FORGED_DELIVERED_TO + "From: Alice Example")
    result = Intake::RecipientResolver.call(Mail.new("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + source),
      owned_names: %w[example.org example.net])
    assert_equal "hello@example.org", result.primary
    assert_equal "hdr:Received", result.routed_via
  end

  test "in mx mode the ingress's X-Original-To on top beats a forged Delivered-To" do
    source = "X-Original-To: support@mail.example.org\n" + mx_source.sub("From: Bob Example", FORGED_DELIVERED_TO + "From: Bob Example")
    result = Intake::RecipientResolver.call(Mail.new(source), owned_names: %w[mail.example.org example.net])
    assert_equal "support@mail.example.org", result.primary
    assert_equal "hdr:X-Original-To", result.routed_via
  end

  test "on the catch-all path a forged Delivered-To does not pick the domain when the host writes X-Original-To" do
    source = hosted_source.sub("Delivered-To: info@example.org", "X-Original-To: careers@example.org")
                          .sub("X-Spam-Status:", FORGED_DELIVERED_TO + "X-Spam-Status:")
    result = resolve_hosted(source, owned: %w[example.org example.net])
    assert_equal "careers@example.org", result.primary
  end

  test "matches and trace are capped for mail to thousands of addresses" do
    to = (1..5000).map { |i| "u#{i}@example.org" }.join(", ")
    mail = Mail.new("X-Original-To: abc123hash@inbound.postmarkapp.com\nFrom: a@sender.example.net\nTo: #{to}\nSubject: many\n\nx")
    result = Intake::RecipientResolver.call(mail, owned_names: %w[example.org])
    assert_equal "u1@example.org", result.primary
    assert_equal Intake::RecipientResolver::MAX_MATCHES, result.matches.size
    assert_equal Intake::RecipientResolver::MAX_TRACE, result.trace.size
  end

  # Mail really sent to the mailbox, with trace headers the sender planted below the host's MX hop.
  def sent_to_mailbox_with_plants(plants)
    hosted_source.sub(MX_FOR, "\tfor <info@example.org>; Fri, 13 Nov 2026 09:00:03 +0000 (UTC)")
                 .sub("To: Careers Team <careers@example.org>", "To: info@example.org")
                 .sub("X-Spam-Status:", plants + "X-Spam-Status:")
  end

  PLANTED_X_ORIGINAL_TO = "X-Original-To: ceo@example.org\n".freeze
  PLANTED_RECEIVED = "Received: from fake by fake for <probe-deadbeef@example.org>; Fri, 13 Nov 2026 09:00:00 +0000\n".freeze
  MX_HOST = { "info@example.org" => "mx1.mailhost.example.net" }.freeze

  test "residual without an MX host: a header planted below the MX hop relabels mail sent to the mailbox" do
    result = resolve_hosted(sent_to_mailbox_with_plants(PLANTED_X_ORIGINAL_TO))
    assert_equal "ceo@example.org", result.primary, "documented as accepted; set the MX host to close it"
  end

  test "with the MX host set, its hop is final even when it names the mailbox" do
    [ PLANTED_X_ORIGINAL_TO, PLANTED_RECEIVED ].each do |plant|
      result = resolve_hosted(sent_to_mailbox_with_plants(plant), mailboxes: MX_HOST)
      assert_equal "info@example.org", result.primary, plant
      assert_equal "hdr:Delivered-To", result.routed_via
      assert_includes result.trace, { "header" => "Received", "address" => "info@example.org" }
    end
  end

  test "with the MX host set, its hop names the recipient and planted lines below it are ignored" do
    source = hosted_source.sub("X-Spam-Status:", PLANTED_X_ORIGINAL_TO + PLANTED_RECEIVED + "X-Spam-Status:")
    result = resolve_hosted(source, mailboxes: MX_HOST)
    assert_equal "careers@example.org", result.primary
    assert_equal "catch-all:Received", result.routed_via
  end

  test "with the MX host set and several recipients on its hop, only fields above it count, then To" do
    source = without_mx_for.sub("To: Careers Team <careers@example.org>", "To: press@example.org, careers@example.org")
                           .sub("X-Spam-Status:", PLANTED_X_ORIGINAL_TO + "X-Spam-Status:")
    result = resolve_hosted(source, mailboxes: MX_HOST)
    assert_equal "press@example.org", result.primary
    assert_equal "catch-all:To", result.routed_via

    above = source.sub("Delivered-To: info@example.org", "X-Delivered-To: jobs@example.org\nDelivered-To: info@example.org")
    assert_equal "jobs@example.org", resolve_hosted(above, mailboxes: MX_HOST).primary
  end

  test "with the MX host set but no hop by it, the mailbox stays and the trace says why" do
    result = resolve_hosted(mailboxes: { "info@example.org" => "mx9.elsewhere.example.net" })
    assert_equal "info@example.org", result.primary
    assert_includes result.trace, { "header" => "catch_all_mx_host_missing", "address" => "mx9.elsewhere.example.net" }
  end

  test "an MX host that also names the host's outbound hop fails closed" do
    # mailhost.example.net matches the redirect's outbound hop first, whose for is the inbound address.
    result = resolve_hosted(mailboxes: { "info@example.org" => "mailhost.example.net" })
    assert_equal "info@example.org", result.primary
    assert_equal "hdr:Delivered-To", result.routed_via
  end

  test "an MX host matches by label, not by bare suffix" do
    result = resolve_hosted(mailboxes: { "info@example.org" => "x1.mailhost.example.net" })
    assert_includes result.trace, { "header" => "catch_all_mx_host_missing", "address" => "x1.mailhost.example.net" }
  end
end
