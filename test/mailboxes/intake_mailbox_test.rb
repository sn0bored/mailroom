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
    second_source = forwarded_source.sub("X-Original-To: <hello@example.org>", "X-Original-To: <hi@example.com>")
    second = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + second_source)

    assert_equal @domain, first.domain
    assert second, "the second domain's copy is stored, not merged away"
    assert_equal other, second.domain
    assert_equal "queued", second.forward_status
    assert_equal 2, Message.count
    assert_enqueued_with(job: ForwardCopyJob, args: [ first.id ])
    assert_enqueued_with(job: ForwardCopyJob, args: [ second.id ])
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

  test "our own instance header marks a loop and skips forwarding" do
    source = "X-Mailroom-Instance: #{Mailroom.instance_id}\nX-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source
    message = receive_source(source)
    assert_equal "loop", message.routed_via
    assert_equal "skipped:loop", message.forward_status
  end

  test "a probe marks the domain and is not forwarded" do
    source = "X-Mailroom-Instance: #{Mailroom.instance_id}\n" + forwarded_source.gsub("hello@example.org", @domain.probe_address)
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
end
