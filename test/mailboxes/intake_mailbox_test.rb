require "test_helper"

class IntakeMailboxTest < ActiveSupport::TestCase
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
  end

  test "unknown domain is stored as unrouted, never dropped" do
    message = receive_source(mx_source)
    assert message
    assert_nil message.domain
    assert_equal "unrouted", message.routed_via
    assert_equal "skipped:unrouted", message.forward_status
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

  test "our own instance header marks a loop and skips forwarding" do
    source = "X-Mailroom-Instance: #{Mailroom.instance_id}\nX-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source
    message = receive_source(source)
    assert_equal "loop", message.routed_via
    assert_equal "skipped:loop", message.forward_status
  end

  test "a probe marks the domain and is not forwarded" do
    source = forwarded_source.gsub("hello@example.org", @domain.probe_address)
    message = receive_source(source)
    assert_equal @domain.probe_address, message.to_address
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
