class OutboundDeliveryJob < ApplicationJob
  TRANSPORT_ERRORS = [ Postmark::HttpClientError, Postmark::InternalServerError,
    Postmark::UnexpectedHttpResponseError, Postmark::TimeoutError,
    Timeout::Error, SocketError, IOError, SystemCallError ].freeze

  retry_on(*TRANSPORT_ERRORS, wait: 5.seconds, attempts: 3) do |job, error|
    job.mark_failed(OutboundMessage.find(job.arguments.first), error)
  end

  def perform(id)
    record = OutboundMessage.find(id)
    return unless record.status == "queued"

    delivery = OutboundMailer.compose(record).deliver_now
    provider_id = delivery.postmark_message_id if delivery.respond_to?(:postmark_message_id)
    record.update!(status: "sent", sent_at: Time.current,
      postmark_message_id: provider_id.presence || delivery.message_id, error: nil)
    Audit.record("outbound.sent", actor: record.api_key || record.user, target: record)
  rescue *TRANSPORT_ERRORS
    raise
  rescue StandardError => error
    raise unless record
    mark_failed(record, error)
  end

  def mark_failed(record, error)
    record.update!(status: "failed", error: error.class.name)
    Audit.record("outbound.failed", actor: record.api_key || record.user,
      target: record, outcome: "failed", error: error)
  end
end
