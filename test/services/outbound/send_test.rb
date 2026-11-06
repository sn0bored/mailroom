require "test_helper"
require_relative "../../support/outbound_stubs"
using OutboundStubs

class OutboundSendTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @domain = Domain.create!(name: "example.org", send_enabled: true)
    @record = OutboundMessage.create!(from_address: "sender@example.org", to_addresses: [ "recipient@example.net" ])
  end

  test "draft and queued messages can be enqueued" do
    2.times do
      assert_enqueued_with(job: OutboundDeliveryJob, args: [ @record.id ]) { assert_equal @record, Outbound::Send.call(@record) }
      assert_equal "queued", @record.reload.status
    end
  end

  test "unknown inactive and disabled sender domains are denied" do
    @record.from_address = "sender@example.net"
    assert_raises(Outbound::Send::NotAllowed) { Outbound::Send.call(@record) }
    @record.from_address = "sender@example.org"
    @domain.update!(active: false)
    assert_raises(Outbound::Send::NotAllowed) { Outbound::Send.call(@record) }
    @domain.update!(active: true, send_enabled: false)
    assert_raises(Outbound::Send::NotAllowed) { Outbound::Send.call(@record) }
    assert_no_enqueued_jobs
  end

  test "key domain restriction is enforced" do
    key, = ApiKey.generate(name: "Test", scopes: [ "mail:send" ], allowed_from_domains: [ "example.net" ])
    @record.api_key = key
    assert_raises(Outbound::Send::NotAllowed) { Outbound::Send.call(@record) }
    key.update!(allowed_from_domains: [ "example.org" ])
    Outbound::Send.call(@record)
    assert_equal "queued", @record.status
  end

  test "empty recipients and sent or failed messages are denied" do
    @record.to_addresses = [ "" ]
    assert_raises(Outbound::Send::NotAllowed) { Outbound::Send.call(@record) }
    @record.to_addresses = [ "recipient@example.net" ]
    %w[sent failed].each do |status|
      @record.status = status
      assert_raises(Outbound::Send::NotAllowed) { Outbound::Send.call(@record) }
    end
  end

  test "user actor persists for the asynchronous audit" do
    user = User.create!(email_address: "owner@example.org", password: "test-password")
    Outbound::Send.call(@record, actor: user)
    assert_equal user, @record.reload.user
  end

  test "probe creates and delivers using sender domain" do
    target = Domain.create!(name: "example.net")
    Mailroom.stub(:forward_sender, "sender@example.org") do
      perform_enqueued_jobs(only: OutboundDeliveryJob) do
        record = Outbound::Probe.call(target)
        assert_equal "probe", record.kind
        assert_equal [ target.probe_address ], record.to_addresses
        assert_equal "Mailroom probe for example.net", record.subject
        assert_equal "sent", record.reload.status
        assert_equal Mailroom.forward_stream, ActionMailer::Base.deliveries.last.message_stream
      end
    end
  end

  test "probe requires a configured and enabled sender" do
    Mailroom.stub(:forward_sender, nil) do
      assert_equal "no sender configured", assert_raises(Outbound::Send::NotAllowed) { Outbound::Probe.call(@domain) }.message
    end
    Mailroom.stub(:forward_sender, "sender@example.net") do
      assert_match "probe sender's domain", assert_raises(Outbound::Send::NotAllowed) { Outbound::Probe.call(@domain) }.message
    end
  end
end
