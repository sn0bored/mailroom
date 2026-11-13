require "test_helper"
require_relative "../support/outbound_stubs"

class IntakeMailboxTest < ActiveSupport::TestCase
  using OutboundStubs
  include ActionMailer::TestHelper
  setup do
    @domain = Domain.create!(name: "example.org", forward_copy_to: "owner@example.net")
    ENV["MAILROOM_FORWARD_SENDER"] = "mailroom@example.org"
  end

  teardown { ENV.delete("MAILROOM_FORWARD_SENDER") }

  test "different first From fields are distinct even with the same last From and Message-ID" do
    source = "From: First <first@example.net>\nFrom: Last <last@example.net>\n" \
      "To: hello@example.org\nSubject: Subject\nMessage-ID: <multiple-from@example.net>\n\nBody"
    first = receive_source(source)
    second = receive_source(source.sub("first@example.net", "other@example.net"))
    assert second, "different visible senders must not merge"
    assert_not_equal first.id, second.id
  end

  test "forward status is queued before the worker can run" do
    ENV["MAILROOM_FORWARD_SENDER"] = "forward@example.org"
    seen = nil
    ForwardCopyJob.stub(:perform_later, ->(id) { seen = Message.find(id).forward_status }) do
      receive_source(forwarded_source)
    end
    assert_equal "queued", seen
  ensure
    ENV.delete("MAILROOM_FORWARD_SENDER")
  end

  test "stores a forwarded message routed to its domain" do
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    assert message, "message was stored"
    assert_equal @domain, message.domain
    assert_equal "hello@example.org", message.to_address
    assert_equal "hdr:X-Original-To", message.routed_via
    assert_equal "alice@sender.example.net", message.from_address
    assert_equal "Alice Example", message.from_name
    assert_equal "Catch-all forward sample", message.subject
    assert_equal "sample-0001@sender.example.net", message.rfc822_message_id
    assert_in_delta(-0.1, message.spam_score, 0.001)
    assert_match(/forwarded by the registrar/, message.body_text)
    assert message.snippet.present?
    assert_not message.list_mail
    assert @domain.reload.last_received_at.present?
    assert_equal "queued", message.forward_status
    assert_enqueued_with(job: ForwardCopyJob, args: [ message.id ])
  end

  test "unknown domain is stored as unrouted, never dropped" do
    message = receive_source(mx_source)
    assert message
    assert_nil message.domain
    assert_equal "unrouted", message.routed_via
    assert_equal "skipped:unrouted", message.forward_status
  end

  test "all mode keeps forwarding unlisted addresses" do
    @domain.update!(forward_mode: "all", forward_addresses: [ "other" ])
    message = receive_source(forwarded_source)
    assert_equal "queued", message.forward_status
    assert_enqueued_with(job: ForwardCopyJob, args: [ message.id ])
  end

  test "listed mode accepts local parts and full addresses case insensitively" do
    [ "HELLO", "Hello@Example.ORG" ].each_with_index do |address, index|
      @domain.update!(forward_mode: "listed", forward_addresses: [ address ])
      message = receive_source(forwarded_source.sub("sample-0001", "listed-#{index}"))
      assert_equal "queued", message.forward_status
      assert_enqueued_with(job: ForwardCopyJob, args: [ message.id ])
    end
  end

  test "unlisted and off mail is stored without queuing copies" do
    @domain.update!(forward_mode: "listed", forward_addresses: [ "other" ])
    assert_no_enqueued_jobs(only: ForwardCopyJob) do
      message = receive_source(forwarded_source)
      assert_equal "skipped:not_listed", message.forward_status
      @domain.update!(forward_mode: "off")
      message = receive_source(forwarded_source.sub("sample-0001", "off-0001"))
      assert_equal "skipped:forward_off", message.forward_status
    end
    assert_equal 2, @domain.messages.count
  end

  test "no target takes precedence over disabled forwarding" do
    @domain.update!(forward_mode: "off", forward_copy_to: nil)
    Mailroom.stub(:default_forward_to, nil) do
      assert_equal "skipped:no_target", receive_source(forwarded_source).forward_status
    end
  end

  test "blocked addresses and domains retain mail and routing without forwarding" do
    [ "alice@sender.example.net", "sender.example.net" ].each_with_index do |pattern, index|
      block = BlockedSender.create!(pattern: pattern)
      assert_no_enqueued_jobs(only: ForwardCopyJob) do
        message = receive_source(forwarded_source.sub("sample-0001", "blocked-#{index}"))
        assert message.blocked?
        assert_equal @domain, message.domain
        assert_equal "hdr:X-Original-To", message.routed_via
        assert_equal "skipped:blocked", message.forward_status
        assert message.body_text.present?
      end
      block.destroy!
    end
  end

  test "blocked unrouted mail is also retained and marked blocked" do
    BlockedSender.create!(pattern: "sender.example.net")
    @domain.destroy!
    message = receive_source(forwarded_source)
    assert message.blocked?
    assert_equal "unrouted", message.routed_via
    assert_equal "skipped:blocked", message.forward_status
  end

  test "forward throttle spans domains and expires an hour after the first copy" do
    Domain.create!(name: "example.net", forward_copy_to: "owner@example.org")
    cache = ActiveSupport::Cache::MemoryStore.new
    start = Time.current.change(usec: 0)
    Rails.stub(:cache, cache) do
      travel_to start do
        5.times do |index|
          source = forwarded_source.sub("sample-0001", "throttle-#{index}")
          source = source.gsub("hello@example.org", "hello@example.net") if index.odd?
          message = receive_source(source)
          assert_equal "queued", message.forward_status
          assert_emails(1) { ForwardCopyJob.perform_now(message.id) }
          assert_equal "sent", message.reload.forward_status
        end
      end
      travel_to start + 30.minutes do
        message = receive_source(forwarded_source.sub("sample-0001", "throttled"))
        assert_no_emails { ForwardCopyJob.perform_now(message.id) }
        assert_equal "skipped:throttled", message.reload.forward_status
        assert message.body_text.present?
      end
      travel_to start + 1.hour do
        message = receive_source(forwarded_source.sub("sample-0001", "after-expiry"))
        assert_emails(1) { ForwardCopyJob.perform_now(message.id) }
        assert_equal "sent", message.reload.forward_status
      end
    end
  end

  test "the same message arriving twice merges into one row" do
    first = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    second_source = forwarded_source.sub("X-Original-To: <hello@example.org>", "X-Original-To: <hi@example.org>")
    second = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + second_source)
    assert_nil second, "no second Message row"
    assert_equal 1, Message.count
    assert_equal %w[hello@example.org hi@example.org], first.reload.matched_addresses.sort
    assert first.routing_trace.any? { |t| t["header"] == "duplicate" }
  end

  test "a copy to a second owned domain with a distinct forward target is not dropped as a duplicate" do
    other = Domain.create!(name: "example.com", forward_copy_to: "other@example.com")
    first = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    # The registrar's copy for example.com names example.com in its Received lines too.
    second_source = forwarded_source.sub("X-Original-To: <hello@example.org>", "X-Original-To: <hi@example.com>")
                                    .gsub("for <hello@example.org>", "for <hi@example.com>")
    second = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + second_source)

    assert_equal @domain, first.domain
    assert second, "the second domain's copy is stored, not merged away"
    assert_equal other, second.domain
    assert_equal "queued", second.forward_status
    assert_equal 2, Message.count
    assert_enqueued_with(job: ForwardCopyJob, args: [ first.id ])
    assert_enqueued_with(job: ForwardCopyJob, args: [ second.id ])
  end

  test "a re-delivery to one of several distinct-target domains merges into that domain's row" do
    org_domain = @domain
    com_domain = Domain.create!(name: "example.com", forward_copy_to: "other@example.com")
    to_com = forwarded_source.sub("X-Original-To: <hello@example.org>", "X-Original-To: <hi@example.com>")
                             .gsub("for <hello@example.org>", "for <hi@example.com>")

    org = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    com = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + to_com)
    # A third webhook: the same Message-ID delivered to example.com again (a provider re-delivery).
    # Vary only the ignored provider address so the raw bytes differ and ActionMailbox's own
    # checksum dedup lets it through to our routing-level dedup.
    redelivery = receive_source("X-Original-To: def456relay@inbound.postmarkapp.com\n" + to_com)

    assert_equal org_domain, org.domain
    assert_equal com_domain, com.domain
    assert_nil redelivery, "the re-delivery is a true duplicate of the example.com copy"
    assert_equal 2, Message.count
    assert com.reload.routing_trace.any? { |t| t["header"] == "duplicate" },
      "the duplicate merged into the matching example.com row"
    assert_not org.reload.routing_trace.any? { |t| t["header"] == "duplicate" },
      "the unrelated example.org row is left untouched"
  end

  test "a duplicate to a second domain sharing the same forward target still merges into one row" do
    Domain.create!(name: "example.com", forward_copy_to: "owner@example.net")
    first = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    second_source = forwarded_source.sub("X-Original-To: <hello@example.org>", "X-Original-To: <hi@example.com>")
    second = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + second_source)

    assert_nil second, "same forward destination is a true duplicate, not a second copy"
    assert_equal 1, Message.count
    assert_enqueued_with(job: ForwardCopyJob, args: [ first.id ])
  end

  test "a loop marker for this message's own Message-ID marks a loop and skips forwarding" do
    marker = LoopMarker.stamp("<sample-0001@sender.example.net>")
    source = "#{LoopMarker::HEADER}: #{marker}\nX-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source
    message = receive_source(source)
    assert_equal "loop", message.routed_via
    assert_equal "skipped:loop", message.forward_status
  end

  test "a real forward copy that comes back is caught as a loop" do
    original = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    copy = ForwardMailer.copy(original).message
    returned = receive_source("X-Original-To: hello@example.org\r\n" + copy.encoded)
    assert_equal "loop", returned.routed_via
    assert_equal "skipped:loop", returned.forward_status
  end

  test "a marker copied from one message does not suppress the forward copy of another" do
    original = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    marker = ForwardMailer.copy(original).message[LoopMarker::HEADER].value
    other = forwarded_source.sub("sample-0001@", "other-0001@")
    # The old loop key was the instance id, visible on every reply; it means nothing now either.
    source = "#{LoopMarker::HEADER}: #{marker}\nX-Mailroom-Instance: #{Mailroom.instance_id}\n" \
      "X-Original-To: abc123hash@inbound.postmarkapp.com\n" + other
    message = receive_source(source)
    assert_equal "hdr:X-Original-To", message.routed_via
    assert_equal "queued", message.forward_status
  end

  test "a probe marks the domain and is not forwarded" do
    source = "#{LoopMarker::HEADER}: #{LoopMarker.stamp('<sample-0001@sender.example.net>')}\n" +
      forwarded_source.gsub("hello@example.org", @domain.probe_address)
    message = receive_source(source)
    assert_equal @domain.probe_address, message.to_address
    assert_equal "hdr:X-Original-To", message.routed_via, "a returning probe is not a loop"
    assert @domain.reload.probe_received_at.present?
    assert_equal "skipped:probe", message.forward_status
  end

  test "list mail and spam are stored but not forwarded" do
    listed = receive_source("List-Id: <news.example.net>\n" + forwarded_source)
    assert listed.list_mail
    assert_equal "skipped:list", listed.forward_status

    spam = receive_source(forwarded_source.sub("X-Spam-Score: -0.1", "X-Spam-Score: 9.5").sub("sample-0001", "sample-0003"))
    assert_in_delta 9.5, spam.spam_score, 0.001
    assert_equal "skipped:spam", spam.forward_status
  end

  test "without a mail provider the copy is skipped, not attempted" do
    ActionMailer::Base.delivery_method = :smtp
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    assert_equal "skipped:no_provider", message.forward_status
  ensure
    ActionMailer::Base.delivery_method = :test
  end

  test "html only mail gets a text body" do
    source = "From: a@sender.example.net\nTo: hello@example.org\nSubject: html\nMessage-ID: <h1@sender.example.net>\nContent-Type: text/html; charset=UTF-8\n\n<p>Hello <b>there</b></p>"
    message = receive_source(source)
    assert message.has_html
    assert_equal "Hello there", message.body_text
  end

  test "attachments are stored" do
    mail = Mail.new do
      from "a@sender.example.net"
      to "hello@example.org"
      subject "with file"
      body "see attached"
      add_file filename: "note.txt", content: "plain text inside"
    end
    message = receive_source(mail.to_s)
    assert_equal 1, message.attachments.count
    assert_equal "note.txt", message.attachments.first.filename.to_s
  end

  test "unparseable input still leaves a row behind" do
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!("garbage\x00\xff")
    inbound.route
    assert Message.exists?(inbound_email_id: inbound.id)
  end

  test "a hosted catch-all mailbox resolves to the address the sender used" do
    @domain.update!(catch_all_mailbox: "info@example.org", forward_mode: "listed", forward_addresses: [ "careers" ])
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + hosted_source)
    assert_equal @domain, message.domain
    assert_equal "careers@example.org", message.to_address
    assert_equal "catch-all:Received", message.routed_via
    assert_equal %w[info@example.org careers@example.org], message.matched_addresses
    assert message.routing_trace.include?({ "header" => "catch_all_mailbox", "address" => "info@example.org" })
    assert_equal "queued", message.forward_status, "listed forwarding sees the recovered address"
    assert_enqueued_with(job: ForwardCopyJob, args: [ message.id ])
  end

  test "without a catch-all mailbox, hosted mail still lands as the mailbox" do
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + hosted_source)
    assert_equal @domain, message.domain
    assert_equal "info@example.org", message.to_address
    assert_equal "hdr:Delivered-To", message.routed_via
  end

  test "bcc and multi-recipient mail through a hosted mailbox stays on its domain" do
    @domain.update!(catch_all_mailbox: "info@example.org")
    Domain.create!(name: "example.net")
    bcc = hosted_source.sub("To: Careers Team <careers@example.org>", "To: someone@example.net").sub("hosted-0001", "hosted-bcc")
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + bcc)
    assert_equal @domain, message.domain
    assert_equal "careers@example.org", message.to_address

    several = hosted_source.sub("\tfor <careers@example.org>; ", "\t").sub("hosted-0001", "hosted-several")
                           .sub("To: Careers Team <careers@example.org>", "To: someone@example.net, press@example.org, careers@example.org")
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + several)
    assert_equal @domain, message.domain
    assert_equal "press@example.org", message.to_address
    assert_equal "catch-all:To", message.routed_via
  end

  test "a probe sent through a hosted mailbox is recognised, not flagged as a loop" do
    @domain.update!(catch_all_mailbox: "info@example.org")
    source = "X-Mailroom-Instance: #{Mailroom.instance_id}\nX-Original-To: abc123hash@inbound.postmarkapp.com\n" +
      hosted_source.gsub("careers@example.org", @domain.probe_address)
    message = receive_source(source)
    assert_equal @domain.probe_address, message.to_address
    assert_equal "catch-all:Received", message.routed_via
    assert @domain.reload.probe_received_at.present?
    assert_equal "skipped:probe", message.forward_status
  end

  test "trace headers forged below the host's MX hop do not misfile hosted mail" do
    @domain.update!(catch_all_mailbox: "info@example.org")
    forged = "X-Original-To: ceo@example.org\nDelivered-To: ceo@example.org\n" \
             "Received: from forged.sender.example.net by mx1.mailhost.example.net with ESMTP id FORGED\n" \
             "\tfor <ceo@example.org>; Fri, 13 Nov 2026 08:59:59 +0000 (UTC)\n"
    source = hosted_source.sub("X-Spam-Status:", forged + "X-Spam-Status:")
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + source)
    assert_equal "careers@example.org", message.to_address
    assert_equal "catch-all:Received", message.routed_via
  end

  test "with the mail host's MX server set, mail sent to the mailbox stays with it despite planted headers" do
    @domain.update!(catch_all_mailbox: "info@example.org", catch_all_mx_host: "mx1.mailhost.example.net")
    source = hosted_source.sub("for <careers@example.org>", "for <info@example.org>")
                          .sub("To: Careers Team <careers@example.org>", "To: info@example.org")
                          .sub("X-Spam-Status:", "X-Original-To: ceo@example.org\nX-Spam-Status:")
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + source)
    assert_equal "info@example.org", message.to_address
    assert_equal "hdr:Delivered-To", message.routed_via
  end

  test "a forged Delivered-To does not move registrar mail to another owned domain" do
    Domain.create!(name: "example.net", forward_copy_to: "client@example.net")
    source = forwarded_source.sub("From: Alice Example", "Delivered-To: boss@example.net\nFrom: Alice Example")
    message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + source)
    assert_equal @domain, message.domain
    assert_equal "hello@example.org", message.to_address
  end

  def nested_source(depth)
    body = +""
    depth.times { |i| body << "Content-Type: multipart/mixed; boundary=\"b#{i}\"\n\n--b#{i}\n" }
    body << "Content-Type: text/html\n\n<p>leaf</p>\n"
    (depth - 1).downto(0) { |i| body << "--b#{i}--\n" }
    "X-Original-To: hello@example.org\nFrom: Mallory <m@sender.example.net>\nTo: hello@example.org\n" \
      "Subject: nest #{depth}\nMessage-ID: <nest-#{depth}@sender.example.net>\nMIME-Version: 1.0\n" + body
  end

  test "over-deep MIME is stored unparsed as an error and not forwarded" do
    [ 33, 3000 ].each do |depth|
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(nested_source(depth))
      assert_no_enqueued_jobs(only: ForwardCopyJob) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        inbound.route
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2, "depth #{depth} is not parsed"
      end
      assert inbound.reload.delivered?, "depth #{depth} leaves nothing in processing"
      message = Message.find_by!(inbound_email_id: inbound.id)
      assert_equal "error", message.routed_via
      assert_equal "MimeTooDeep", message.parse_error
      assert_equal "skipped:mime_too_deep", message.forward_status
      assert_equal "nest #{depth}", message.subject
      assert_equal "m@sender.example.net", message.from_address
      assert_includes message.routing_trace, { "header" => "mime_depth", "address" => "over 32 levels, not parsed" }
      assert_equal nested_source(depth), message.raw_source, "the raw message is kept"
    end
  end

  test "ordinary nesting is still parsed" do
    message = receive_source(nested_source(4))
    assert_equal "hdr:X-Original-To", message.routed_via
    assert message.has_html
  end

  test "MIME bypasses are rejected quickly even without the pre-scan" do
    sources = [
      nested_source(33), nested_source(3000),
      nested_source(1000).gsub(/^(--b\d+)$/, "\\1--x\n\\1"),
      nested_source(1000).gsub('boundary="', 'boundary*0="'),
      nested_source(1000).gsub('boundary="', 'boundary*="us-ascii\'\'')
    ]
    sources.each do |source|
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Intake::MimeDepth.stub(:call, 0) { inbound.route }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
      message = Message.find_by!(inbound_email_id: inbound.id)
      assert_equal "MimeTooDeep", message.parse_error
      assert_equal "skipped:mime_too_deep", message.forward_status
      assert_equal source, message.raw_source
      assert inbound.reload.delivered?
    end
    assert_equal "hdr:X-Original-To", receive_source(nested_source(32)).routed_via
  end

  test "body boundary text and DSN digests are accepted quickly" do
    digest = +"Content-Type: multipart/digest; boundary=digest\n\n"
    40.times do |i|
      digest << "--digest\nContent-Type: text/rfc822-headers\n\nContent-Type: multipart/mixed; boundary=b#{i}\n\n"
    end
    digest << "--digest--\n"
    [ "Content-Type: text/plain\n\n" + (" boundary=body\n" * 33), digest ].each do |body|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      message = receive_source("From: sender@example.net\nTo: hello@example.org\nSubject: report\n" + body)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
      assert_nil message.parse_error
      assert_equal "to:To", message.routed_via
    end
  end

  %w[From To Cc Subject].each do |header|
    test "same Message-ID and body with different #{header} is separate mail" do
      source = "From: ceo@bank.test\nTo: hello@example.org\nCc: copy@example.org\nSubject: URGENT wire\n" \
        "Message-ID: <same-id@example.net>\n\nSame body\n"
      first = receive_source(source)
      replacement = header == "Subject" ? "Routine update" : "real@partner.test"
      second = receive_source(source.sub(/^#{header}: .*$/, "#{header}: #{replacement}"))
      assert second, "different #{header} must not merge"
      assert_equal 2, Message.count
      assert_not_equal first.raw_body_digest, second.raw_body_digest
      assert_equal replacement, second.from_address if header == "From"
    end
  end

  test "legacy rows without a digest never merge" do
    source = "From: sender@example.net\nTo: hello@example.org\nSubject: legacy\nMessage-ID: <legacy@example.net>\n\nbody"
    first = receive_source(source)
    first.update!(raw_body_digest: nil)
    assert receive_source("Received: by mx.example.net\n" + source)
    assert_equal 2, Message.count
  end

  test "folded identity headers still merge across delivery paths" do
    source = "From: Sender <sender@example.net>\nTo: hello@example.org, copy@example.org\n" \
      "Cc: other@example.org\nSubject: Routine update\nMessage-ID: <folded@example.net>\n\nbody"
    first = receive_source(source)
    folded = source.sub(", copy", ",\n\tcopy").sub("Routine update", "Routine\n update")
    assert_nil receive_source("Received: by mx.example.net\n" + folded)
    assert_equal 1, Message.count
    assert first.reload.routing_trace.any? { |entry| entry["header"] == "duplicate" }
  end

  test "a stack overflow while parsing still leaves a row and nothing in processing" do
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(forwarded_source)
    Intake::MessageBuilder.stub(:new, ->(*) { raise SystemStackError, "stack level too deep" }) { inbound.route }
    assert inbound.reload.delivered?
    message = Message.find_by!(inbound_email_id: inbound.id)
    assert_equal "error", message.routed_via
    assert_equal "SystemStackError", message.parse_error
  end

  test "a sender who copies a Message-ID and arrives first does not swallow the real message" do
    forged = forwarded_source.sub("From: Alice Example <alice@sender.example.net>", "From: Mallory <m@sender.example.net>")
                             .sub(/This message was sent.*\z/m, "Please wire the money to a new account.\n")
    first = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forged)
    real = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)

    assert real, "the real message gets its own row"
    assert_equal 2, Message.count
    assert_equal "alice@sender.example.net", real.from_address
    assert_match(/forwarded by the registrar/, real.body_text)
    assert_equal "queued", real.forward_status, "different mail gets its own copy"
    assert_enqueued_with(job: ForwardCopyJob, args: [ real.id ])
    assert_includes real.routing_trace, { "header" => "same_message_id", "address" => "message:#{first.id}" }
    assert_equal "queued", first.reload.forward_status
    assert_not first.routing_trace.any? { |t| t["header"] == "duplicate" }
  end

  test "the same body with different line endings is still a duplicate" do
    first = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    again = receive_source("X-Original-To: def456relay@inbound.postmarkapp.com\r\n" + forwarded_source.gsub("\n", "\r\n"))
    assert_nil again
    assert_equal 1, Message.count
    assert first.reload.routing_trace.any? { |t| t["header"] == "duplicate" }
    assert_equal 64, first.raw_body_digest.size
  end

  test "merged matches stay capped" do
    many = (1..60).map { |i| "u#{i}@example.org" }.join(", ")
    first = receive_source("X-Original-To: #{many}\n" + forwarded_source)
    others = (61..120).map { |i| "u#{i}@example.org" }.join(", ")
    assert_nil receive_source("X-Original-To: #{others}\n" + forwarded_source)
    assert_equal 1, Message.count
    assert_equal Intake::RecipientResolver::MAX_MATCHES, first.reload.matched_addresses.size
  end
end
