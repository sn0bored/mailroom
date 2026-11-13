ENV["RAILS_ENV"] ||= "test"
ENV["RAILS_INBOUND_EMAIL_PASSWORD"] ||= "test-ingress-password"
ENV["MAILROOM_INSTANCE_ID"] ||= "test-instance"
ENV["MAILROOM_PORT"] = "3100"
ENV["MAILROOM_PUBLIC_PORT"] = "3101"
ENV.delete("MAILROOM_TRUST_LOCAL")
require_relative "../config/environment"
require "rails/test_help"
# Integration requests arrive on the internal listener by default; the gate's own tests pick a listener.
require_relative "support/listeners"

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    parallelize(workers: 1)
    fixtures :all

    def forwarded_source = file_fixture("forwarded_sample.eml").read
    def mx_source = file_fixture("mx_mode_sample.eml").read

    def receive_source(source)
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
      inbound.route
      inbound.reload
      Message.find_by(inbound_email_id: inbound.id)
    end

    def create_api_key(scopes: %w[mail:read], domains: [])
      ApiKey.generate(name: "test", scopes: scopes, allowed_from_domains: domains)
    end
  end
end
