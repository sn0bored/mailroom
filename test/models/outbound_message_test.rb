require "test_helper"
require Rails.root.join("db/migrate/20261113000000_fail_refused_api_send_drafts")

class OutboundMessageTest < ActiveSupport::TestCase
  def build(**attributes)
    OutboundMessage.new({ from_address: "sender@example.org", to_addresses: [ "recipient@example.net" ] }.merge(attributes))
  end

  test "from_domain reads the address inside a display name" do
    assert_equal "example.org", build(from_address: "sender@example.org").from_domain
    assert_equal "example.org", build(from_address: "Example Sender <Sender@Example.ORG>").from_domain
    assert_equal "example.org", build(from_address: "\"Example, Inc.\" <sender@example.org>").from_domain
    assert_equal "Example Sender", build(from_address: "Example Sender <sender@example.org>").from_mailbox.display_name
  end

  test "from_domain is blank unless from_address is exactly one address" do
    [ nil, "", "garbage", "<<<@@@", "sender@example.org>", "sender@example.org, other@example.net",
      "group: sender@example.org;", "Name <sender@example.org>\r\nBcc: blind@example.net", "\xFF@example.org".b ].each do |from|
      record = build(from_address: from)
      assert_equal "", record.from_domain, from.inspect
      assert_not record.valid?, from.inspect
      assert record.errors.key?(:from_address), from.inspect
    end
  end

  test "an unchanged from address is not re-validated" do
    record = build(from_address: "garbage", status: "queued")
    record.save!(validate: false)
    assert record.update(status: "failed", error: "ArgumentError")
  end

  test "an API send cannot be a draft but owner and agent drafts can" do
    key, = create_api_key(scopes: %w[mail:send mail:draft])
    api_send = build(kind: "api", api_key: key, status: "draft")
    assert_not api_send.valid?
    assert api_send.errors.key?(:status)
    api_send.status = "queued"
    assert api_send.valid?
    assert build(kind: "api", status: "draft").valid?, "owner draft"
    assert build(kind: "reply", api_key: key, status: "draft").valid?, "agent reply draft"
  end

  test "the cleanup migration fails refused API send drafts and leaves other drafts alone" do
    key, = create_api_key(scopes: %w[mail:send mail:draft])
    refused = build(kind: "api", api_key: key, status: "draft").tap { |record| record.save!(validate: false) }
    untouched = [ build(kind: "api", api_key: key, status: "queued"), build(kind: "api", status: "draft"),
      build(kind: "reply", api_key: key, status: "draft") ].each(&:save!)
    before = untouched.map { |record| record.reload.attributes }

    ActiveRecord::Migration.suppress_messages { FailRefusedApiSendDrafts.new.migrate(:up) }
    refused.reload
    assert_equal "failed", refused.status
    assert_equal "refused before upgrade; not sent", refused.error
    assert_equal before, untouched.map { |record| record.reload.attributes }
    assert_empty OutboundMessage.drafts.select(&:api_send?)
  end
end
