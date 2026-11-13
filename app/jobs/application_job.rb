class ApplicationJob < ActiveJob::Base
  # Transient provider/network failures worth retrying rather than failing a delivery on.
  TRANSPORT_ERRORS = [ Postmark::HttpClientError, Postmark::InternalServerError,
    Postmark::UnexpectedHttpResponseError, Postmark::TimeoutError,
    Timeout::Error, SocketError, IOError, SystemCallError ].freeze

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
