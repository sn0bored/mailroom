require "test_helper"
require_relative "../support/outbound_stubs"
using OutboundStubs

class ForwardCopyJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActionMailer::Base.deliveries.clear
    @domain = Domain.create!(name: "example.org", forward_copy_to: "owner@example.net")
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(File.read("test/fixtures/files/forwarded_sample.eml"))
    @record = Message.create!(domain: @domain, inbound_email: inbound, to_address: "inbox@example.org",
      from_address: "sender@example.net", from_name: "Example Sender", subject: "Original", body_text: "Body", received_at: Time.current)
  end

  test "unrouted messages are ignored" do
    @record.update!(domain: nil)
    ForwardCopyJob.perform_now(@record.id)
    assert_nil @record.reload.forward_status
    assert_empty ActionMailer::Base.deliveries
  end

  test "missing target is skipped" do
    @domain.update!(forward_copy_to: nil)
    Setting.where(key: "default_forward_to").delete_all
    Mailroom.stub(:default_forward_to, nil) { ForwardCopyJob.perform_now(@record.id) }
    assert_equal "skipped:no_target", @record.reload.forward_status
    assert_empty ActionMailer::Base.deliveries
  end

  test "queued copies obey changes to domain forwarding mode and addresses" do
    @domain.update!(forward_mode: "off")
    ForwardCopyJob.perform_now(@record.id)
    assert_equal "skipped:forward_off", @record.reload.forward_status
    assert_empty ActionMailer::Base.deliveries
    @domain.update!(forward_mode: "listed", forward_addresses: [ "other" ])
    ForwardCopyJob.perform_now(@record.id)
    assert_equal "skipped:not_listed", @record.reload.forward_status
    assert_empty ActionMailer::Base.deliveries
    @domain.update!(forward_addresses: [ "INBOX@EXAMPLE.ORG" ])
    Mailroom.stub(:forward_sender, "forward@example.org") { ForwardCopyJob.perform_now(@record.id) }
    assert_equal "sent", @record.reload.forward_status
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test "queued copies are blocked when the sender is blocked after intake" do
    BlockedSender.create!(pattern: "example.net")
    ForwardCopyJob.perform_now(@record.id)
    assert @record.reload.blocked?
    assert_equal "skipped:blocked", @record.forward_status
    assert_empty ActionMailer::Base.deliveries
  end

  test "stored blocked mail stays blocked even if the pattern is removed" do
    @record.update!(blocked: true)
    ForwardCopyJob.perform_now(@record.id)
    assert_equal "skipped:blocked", @record.reload.forward_status
    assert_empty ActionMailer::Base.deliveries
  end

  test "throttle normalizes senders and does not share counters between addresses" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stub(:cache, cache) do
      5.times { assert ForwardThrottle.allow?(" SENDER@EXAMPLE.NET ") }
      assert_not ForwardThrottle.allow?("sender@example.net")
      assert ForwardThrottle.allow?("other@example.net")
      key = "forward-throttle:#{Digest::SHA256.hexdigest('sender@example.net')}"
      assert_equal 6, cache.read(key)
    end
  end

  test "missing sender warns once and skips" do
    warnings = []
    Mailroom.stub(:forward_sender, nil) do
      Rails.logger.stub(:warn, ->(line) { warnings << line }) do
        2.times { ForwardCopyJob.perform_now(@record.id) }
      end
    end
    assert_equal "skipped:no_sender", @record.reload.forward_status
    assert_equal 1, warnings.size
    assert_empty ActionMailer::Base.deliveries
  end

  test "forwarded message preserves routing and body" do
    Mailroom.stub(:forward_sender, "forward@example.org") { ForwardCopyJob.perform_now(@record.id) }
    delivery = ActionMailer::Base.deliveries.last
    assert_equal "sent", @record.reload.forward_status
    assert_equal "[example.org] Original", delivery.subject
    assert_equal [ "sender@example.net" ], delivery.reply_to
    assert_equal [ "owner@example.net" ], delivery.to
    assert_equal [ "forward@example.org" ], delivery.from
    assert_equal Mailroom.instance_id, delivery["X-Mailroom-Instance"].value
    assert_equal @record.id.to_s, delivery["X-Mailroom-Message-Id"].value
    assert_equal "inbox@example.org", delivery["X-Mailroom-Original-To"].value
    assert_equal Mailroom.forward_stream, delivery.message_stream
    assert_includes delivery.body.decoded, "Received for inbox@example.org on #{@record.received_at}"
    assert_includes delivery.body.decoded, "From: Example Sender <sender@example.net>\n\nBody"
  end

  test "attachments stop at budget and report remainder" do
    2.times do |index|
      @record.attachments.attach(io: StringIO.new("small"), filename: "sample#{index}.txt", content_type: "text/plain")
    end
    @record.attachments.last.blob.update!(byte_size: ForwardMailer::ATTACHMENT_BUDGET)
    Mailroom.stub(:forward_sender, "forward@example.org") { ForwardCopyJob.perform_now(@record.id) }
    delivery = ActionMailer::Base.deliveries.last
    assert_equal 1, delivery.attachments.size
    assert_equal "small", delivery.attachments.first.decoded
    assert_includes delivery.text_part.decoded, "1 attachment(s) not forwarded; open message #{@record.id} in Mailroom"
  end

  test "original html is included only when available and parsing errors are ignored" do
    @record.has_html = true
    raw = Mail.new do
      text_part { body "text" }
      html_part { content_type "text/html"; body "<p>original</p>" }
    end.to_s
    Mailroom.stub(:forward_sender, "forward@example.org") do
      @record.stub(:raw_source, raw) { assert_equal "<p>original</p>", ForwardMailer.copy(@record).message.html_part.decoded }
      @record.stub(:raw_source, -> { raise ArgumentError }) { assert_nil ForwardMailer.copy(@record).message.html_part }
    end
  end

  test "transient transport failures retry before giving up" do
    attempts = 0
    Mailroom.stub(:forward_sender, "forward@example.org") do
      ForwardMailer.stub(:copy, ->(*) { attempts += 1; raise Postmark::TimeoutError.new(StandardError.new("private")) }) do
        perform_enqueued_jobs(only: ForwardCopyJob) { ForwardCopyJob.perform_later(@record.id) }
      end
    end
    assert_equal 3, attempts, "transient transport errors should be retried like outbound delivery"
    assert_equal "failed:Postmark::TimeoutError", @record.reload.forward_status
  end

  test "failure status contains only class" do
    Mailroom.stub(:forward_sender, "forward@example.org") do
      ForwardMailer.stub(:copy, ->(*) { raise ArgumentError, "private" }) { ForwardCopyJob.perform_now(@record.id) }
    end
    assert_equal "failed:ArgumentError", @record.reload.forward_status
  end
end
