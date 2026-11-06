require "test_helper"

class PostmarkSetupTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :updates
    def initialize = @updates = []
    def update_server_info(attrs) = @updates << attrs
    def server_info = { id: 42, name: "Mailroom", inbound_hash: "abc123hash" }
  end

  test "configure points the webhook at us and stores the inbound hash" do
    client = FakeClient.new
    result = PostmarkSetup.new(token: "t", client: client).configure!(public_host: "mailroom.example.ts.net", password: "pw")
    assert_equal "https://actionmailbox:pw@mailroom.example.ts.net/rails/action_mailbox/postmark/inbound_emails", client.updates.first[:inbound_hook_url]
    assert client.updates.first[:raw_email_enabled]
    assert_equal "abc123hash@inbound.postmarkapp.com", result[:inbound_address]
    assert_equal "42", Setting.get("postmark_server_id")
  end

  test "configure refuses to run without the pieces it needs" do
    assert_raises(ArgumentError) { PostmarkSetup.new(token: nil).configure!(public_host: "h", password: "p") }
    assert_raises(ArgumentError) { PostmarkSetup.new(token: "t", client: FakeClient.new).configure!(public_host: nil, password: "p") }
  end

  test "retry_failed asks Postmark for each parked message" do
    calls = []
    http = lambda do |method, path|
      calls << [ method, path ]
      method == :get ? { "InboundMessages" => [ { "MessageID" => "m1" }, { "MessageID" => "m2" } ] } : { "ErrorCode" => 0 }
    end
    result = PostmarkSetup.new(token: "t", http: http).retry_failed!
    assert_equal({ failed: 2, retried: 2 }, result)
    assert_includes calls, [ :put, "/messages/inbound/m1/retry" ]
  end
end
