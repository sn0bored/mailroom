require "test_helper"
require "fugit"

class OutboundSweepJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { ActionMailer::Base.deliveries.clear }

  def outbound(status, updated_ago)
    record = OutboundMessage.create!(status: status, from_address: "sender@example.org",
      to_addresses: [ "recipient@example.net" ], subject: "Subject", text_body: "Body")
    record.update_columns(updated_at: updated_ago.ago)
    record
  end

  test "requeues a queued row past the grace period but not a fresh one" do
    old = outbound("queued", 20.minutes)
    fresh = outbound("queued", 5.minutes)
    OutboundSweepJob.perform_now
    assert_enqueued_with(job: OutboundDeliveryJob, args: [ old.id ])
    assert_equal 1, enqueued_jobs.count { |job| job["job_class"] == "OutboundDeliveryJob" }
    assert_equal "queued", fresh.reload.status
    assert AuditEvent.exists?(action: "outbound.requeued", target_id: old.id)

    clear_enqueued_jobs
    OutboundSweepJob.perform_now
    assert_no_enqueued_jobs(only: OutboundDeliveryJob)
  end

  test "a requeued row whose original job was only late is delivered once" do
    old = outbound("queued", 20.minutes)
    OutboundDeliveryJob.perform_later(old.id)
    OutboundSweepJob.perform_now
    perform_enqueued_jobs(only: OutboundDeliveryJob)
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal "sent", old.reload.status
  end

  test "fails a stale sending row without resending it and leaves a recent one alone" do
    stale = outbound("sending", 2.hours)
    recent = outbound("sending", 10.minutes)
    OutboundSweepJob.perform_now
    assert_no_enqueued_jobs(only: OutboundDeliveryJob)
    assert_empty ActionMailer::Base.deliveries
    stale.reload
    assert_equal "failed", stale.status
    assert_equal "delivery outcome unknown; check the provider before resending", stale.error
    assert_equal "sending", recent.reload.status

    OutboundDeliveryJob.perform_now(stale.id)
    assert_empty ActionMailer::Base.deliveries
  end

  test "the production schedule runs the sweep" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "sweep_outbound_messages")
    assert_equal OutboundSweepJob, task["class"].constantize
    assert_kind_of Fugit::Cron, Fugit.parse(task["schedule"], multi: :fail)
  end

  test "stale forwarding claims fail with unknown outcome and never resend" do
    inbound = -> { ActionMailbox::InboundEmail.create_and_extract_message_id!("Message-ID: <#{SecureRandom.uuid}@example.net>\n\nBody") }
    stale = Message.create!(inbound_email: inbound.call, received_at: Time.current, forward_status: "sending")
    stale.update_columns(updated_at: 2.hours.ago)
    recent = Message.create!(inbound_email: inbound.call, received_at: Time.current, forward_status: "sending")
    sent = Message.create!(inbound_email: inbound.call, received_at: Time.current, forward_status: "sent")
    sent.update_columns(updated_at: 2.hours.ago)
    assert_no_enqueued_jobs(only: ForwardCopyJob) { OutboundSweepJob.perform_now }
    assert_equal "failed:outcome_unknown", stale.reload.forward_status
    assert_equal "sending", recent.reload.forward_status
    assert_equal "sent", sent.reload.forward_status
    ForwardCopyJob.perform_now(stale.id)
    assert_empty ActionMailer::Base.deliveries
  end
end
