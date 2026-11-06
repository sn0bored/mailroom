require "test_helper"
require_relative "../support/outbound_stubs"
using OutboundStubs

class OutboundDeliveryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActionMailer::Base.deliveries.clear
    @key, = ApiKey.generate(name: "Test", scopes: [ "mail:send" ])
    @record = OutboundMessage.create!(api_key: @key, status: "queued", from_address: "sender@example.org",
      to_addresses: [ "recipient@example.net" ], cc_addresses: [ "copy@example.net" ], bcc_addresses: [ "blind@example.net" ],
      text_body: "Plain body", html_body: "<p>HTML body</p>", subject: "Subject",
      reply_to: "reply@example.org", in_reply_to: "<parent@example.org>", references_header: "<ancestor@example.org>")
  end

  test "delivery stores identifiers and audits the actor" do
    OutboundDeliveryJob.perform_now(@record.id)
    delivery = ActionMailer::Base.deliveries.last
    assert_equal "sent", @record.reload.status
    assert @record.sent_at
    assert_equal delivery.message_id, @record.postmark_message_id
    assert_equal Mailroom.instance_id, delivery["X-Mailroom-Instance"].value
    assert_equal @record.id.to_s, delivery["X-Mailroom-Message-Id"].value
    assert_equal "parent@example.org", delivery.in_reply_to
    assert_equal "ancestor@example.org", delivery.references
    assert_equal [ "reply@example.org" ], delivery.reply_to
    assert_equal [ "copy@example.net" ], delivery.cc
    assert_equal [ "blind@example.net" ], delivery.bcc
    assert_equal "Plain body", delivery.text_part.decoded
    assert_equal "<p>HTML body</p>", delivery.html_part.decoded
    audit = AuditEvent.find_by!(action: "outbound.sent", target_id: @record.id)
    assert_equal @key.id, audit.actor_id
    assert_equal "ApiKey", audit.actor_type
    OutboundDeliveryJob.perform_now(@record.id)
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test "failure stores class only" do
    OutboundMailer.stub(:compose, ->(*) { raise ArgumentError, "private body" }) do
      OutboundDeliveryJob.perform_now(@record.id)
    end
    assert_equal "failed", @record.reload.status
    assert_equal "ArgumentError", @record.error
    assert_equal "ArgumentError", AuditEvent.find_by!(action: "outbound.failed").error_class
  end

  test "transport failures retry twice then fail" do
    attempts = 0
    OutboundMailer.stub(:compose, ->(*) { attempts += 1; raise Postmark::TimeoutError.new(StandardError.new("private")) }) do
      perform_enqueued_jobs(only: OutboundDeliveryJob) { OutboundDeliveryJob.perform_later(@record.id) }
    end
    assert_equal 3, attempts
    assert_equal "failed", @record.reload.status
    assert_equal "Postmark::TimeoutError", @record.error
    assert_equal 1, AuditEvent.where(action: "outbound.failed", target_id: @record.id).count
  end
end
