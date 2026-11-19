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
    assert_nil delivery[LoopMarker::HEADER], "an ordinary send carries no loop marker"
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

  test "a non-transport error before delivery marks the message failed" do
    OutboundMailer.stub(:compose, ->(*) { raise ArgumentError, "private body" }) do
      perform_enqueued_jobs(only: OutboundDeliveryJob) { OutboundDeliveryJob.perform_later(@record.id) }
    end
    assert_equal "failed", @record.reload.status
    assert_equal "ArgumentError", @record.error
    assert_empty ActionMailer::Base.deliveries
  end

  test "two jobs racing on one row deliver it exactly once" do
    second = OutboundDeliveryJob.new(@record.id)
    compose = OutboundMailer.method(:compose)
    raced = false
    # The second job runs once, while the first holds the claim and is about to deliver.
    race = ->(record) { second.perform_now unless raced; raced = true; compose.call(record) }
    OutboundMailer.stub(:compose, race) do
      OutboundDeliveryJob.perform_now(@record.id)
    end
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal "sent", @record.reload.status
    assert_not_equal second.job_id, @record.delivery_job_id
  end

  test "duplicate enqueues for one row deliver it exactly once" do
    perform_enqueued_jobs(only: OutboundDeliveryJob) do
      3.times { OutboundDeliveryJob.perform_later(@record.id) }
    end
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal 1, AuditEvent.where(action: "outbound.sent", target_id: @record.id).count
  end

  test "a retry after a transport error reclaims its own row and delivers" do
    attempts = 0
    compose = OutboundMailer.method(:compose)
    flaky = ->(record) { attempts += 1; attempts == 1 ? raise(Postmark::TimeoutError.new(StandardError.new("private"))) : compose.call(record) }
    job = OutboundDeliveryJob.new(@record.id)
    OutboundMailer.stub(:compose, flaky) do
      perform_enqueued_jobs(only: OutboundDeliveryJob) { job.enqueue }
    end
    assert_equal 2, attempts
    assert_equal 1, ActionMailer::Base.deliveries.size
    @record.reload
    assert_equal "sent", @record.status
    assert_equal job.job_id, @record.delivery_job_id
    assert_equal 2, @record.delivery_attempt
  end

  test "redispatching the same serialized execution does not deliver again" do
    job = OutboundDeliveryJob.new(@record.id)
    serialized = job.serialize
    # The provider accepts the message, but the worker stops before recording the outcome.
    job.stub(:record_sent, ->(*) { }) { job.perform_now }
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal "sending", @record.reload.status

    replay = OutboundDeliveryJob.deserialize(serialized)
    messages = []
    Rails.logger.stub(:info, ->(message) { messages << message }) do
      assert_no_difference("ActionMailer::Base.deliveries.size") { replay.perform_now }
    end
    assert_equal job.job_id, replay.job_id
    assert_equal job.executions, replay.executions
    assert_equal "sending", @record.reload.status
    assert_equal 1, @record.delivery_attempt
    assert messages.compact.any? { |message| message.include?("OutboundDeliveryJob: skipped message") }
  end

  test "a legacy sending claim without an attempt cannot be redispatched" do
    job = OutboundDeliveryJob.new(@record.id)
    @record.update!(status: "sending", delivery_job_id: job.job_id)
    job.perform_now
    assert_empty ActionMailer::Base.deliveries
    assert_equal "sending", @record.reload.status
    assert_nil @record.delivery_attempt
  end

  test "another job cannot take over a row that is being delivered" do
    @record.update!(status: "sending", delivery_job_id: "another-job")
    OutboundDeliveryJob.perform_now(@record.id)
    assert_empty ActionMailer::Base.deliveries
    assert_equal "sending", @record.reload.status
    assert_equal "another-job", @record.delivery_job_id
  end

  test "a message that was delivered stays sent when the bookkeeping after it fails" do
    [ Errno::ECONNRESET, RuntimeError ].each do |error_class|
      ActionMailer::Base.deliveries.clear
      record = OutboundMessage.create!(api_key: @key, status: "queued", from_address: "sender@example.org",
        to_addresses: [ "recipient@example.net" ], subject: "Subject", text_body: "Body")
      Audit.stub(:record, ->(*, **) { raise error_class, "audit down" }) do
        perform_enqueued_jobs(only: OutboundDeliveryJob) { OutboundDeliveryJob.perform_later(record.id) }
      end
      assert_equal 1, ActionMailer::Base.deliveries.size, error_class.name
      record.reload
      assert_equal "sent", record.status, error_class.name
      assert record.sent_at
      assert_nil record.error
    end
  end

  test "a missing message is ignored" do
    assert_nothing_raised { OutboundDeliveryJob.perform_now(0) }
    assert_empty ActionMailer::Base.deliveries
  end
end
