require "test_helper"

class ApiUnreadControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "example.org:8443"
    @pollystop = Domain.create!(name: "pollystop.com")
    @tyb = Domain.create!(name: "tyb.ai")
    _, @token = ApiKey.generate(name: "Heartbeat", scopes: [ "mail:read" ])
  end

  def get_unread(token = @token)
    get "/api/v1/unread", headers: token ? { "Authorization" => "Bearer #{token}" } : {}
  end

  def inbound(domain, read:, archived: false)
    source = file_fixture("forwarded_sample.eml").read.sub("sample-0001@", "#{SecureRandom.hex(8)}@")
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    Message.create!(inbound_email: inbound, domain: domain, from_address: "sender@example.net",
      subject: "Hi", received_at: Time.current, matched_addresses: [ "inbox@#{domain.name}" ],
      read_at: read ? Time.current : nil, archived_at: archived ? Time.current : nil)
  end

  test "authentication is required" do
    get_unread(nil)
    assert_response :unauthorized
  end

  test "a key without the mail:read scope is forbidden" do
    _, send_only = ApiKey.generate(name: "Sender", scopes: [ "mail:send" ])
    get_unread(send_only)
    assert_response :forbidden
  end

  test "reports total and per-domain unread counts" do
    inbound(@pollystop, read: false)
    inbound(@pollystop, read: false)
    inbound(@pollystop, read: false)
    inbound(@pollystop, read: true)
    inbound(@tyb, read: false)
    inbound(@tyb, read: false)
    inbound(@tyb, read: true)

    get_unread
    assert_response :ok
    body = response.parsed_body
    assert_equal 5, body["total_unread"]
    assert_equal([ { "domain" => "pollystop.com", "unread" => 3 }, { "domain" => "tyb.ai", "unread" => 2 } ],
      body["domains"])
    assert body["checked_at"].present?
  end

  test "archived unread messages are excluded from the counts" do
    inbound(@pollystop, read: false)
    inbound(@pollystop, read: false, archived: true)

    get_unread
    assert_response :ok
    assert_equal 1, response.parsed_body["total_unread"]
    assert_equal 1, response.parsed_body["domains"].find { |d| d["domain"] == "pollystop.com" }["unread"]
  end

  test "empty inbox returns zero with every active domain" do
    get_unread
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["total_unread"]
    assert_equal [ "pollystop.com", "tyb.ai" ], body["domains"].map { |d| d["domain"] }
    assert body["domains"].all? { |d| d["unread"].zero? }
  end

  test "inactive domains are omitted" do
    inactive = Domain.create!(name: "retired.dev", active: false)
    inbound(inactive, read: false)

    get_unread
    assert_response :ok
    body = response.parsed_body
    assert_equal 0, body["total_unread"]
    assert_not_includes body["domains"].map { |d| d["domain"] }, "retired.dev"
  end
end
