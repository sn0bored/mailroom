require "test_helper"

class ApiSendControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    host! "example.org:8443"
    @domain = Domain.create!(name: "example.org", send_enabled: true)
    @key, @token = ApiKey.generate(name: "Test", scopes: [ "mail:send" ], allowed_from_domains: [ "example.org" ])
    @payload = { from: "sender@example.org", to: "recipient@example.net", subject: "Test", text: "Body" }
  end

  def send_request(payload = @payload, token = @token)
    post "/api/v1/send", params: payload, headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  test "authentication is required" do
    send_request(@payload, nil)
    assert_response :unauthorized
  end

  test "send scope is required" do
    @key.update!(scopes: [ "mail:read" ])
    send_request
    assert_response :forbidden
    assert_equal "scope", response.parsed_body["reason"]
  end

  test "domain restriction is enforced" do
    @key.update!(allowed_from_domains: [ "example.net" ])
    assert_no_enqueued_jobs { send_request }
    assert_response :forbidden
  end

  test "invalid record returns details" do
    send_request(@payload.merge(to: []))
    assert_response :unprocessable_entity
    assert_equal "invalid", response.parsed_body["error"]
    assert response.parsed_body["details"].any?
  end

  test "success enqueues delivery and audits" do
    assert_enqueued_jobs 1, only: OutboundDeliveryJob do
      send_request(@payload.merge(to: [ "recipient@example.net" ], cc: "copy@example.net", bcc: [ "blind@example.net" ],
        html: "<p>Body</p>", reply_to: "reply@example.org", in_reply_to: "<parent@example.org>"))
    end
    assert_response :accepted
    record = OutboundMessage.find(response.parsed_body["id"])
    assert_equal "queued", record.status
    assert_equal [ "copy@example.net" ], record.cc_addresses
    assert_equal [ "blind@example.net" ], record.bcc_addresses
    assert_equal "<p>Body</p>", record.html_body
    audit = AuditEvent.find_by!(action: "api.send", target_id: record.id)
    assert_equal @key.id, audit.actor_id
    assert audit.ip.present?
  end

  test "idempotent replay returns the original record without another job" do
    send_request(@payload.merge(idempotency_key: "request-one"))
    assert_response :accepted
    id = response.parsed_body["id"]
    assert_no_difference "OutboundMessage.count" do
      assert_no_enqueued_jobs { send_request(@payload.merge(idempotency_key: "request-one")) }
    end
    assert_response :ok
    assert_equal id, response.parsed_body["id"]
    assert_equal true, response.parsed_body["idempotent"]
  end

  test "idempotency keys are scoped to api key" do
    send_request(@payload.merge(idempotency_key: "request-one"))
    id = response.parsed_body["id"]
    _, token = ApiKey.generate(name: "Other", scopes: [ "mail:send" ])
    send_request(@payload.merge(idempotency_key: "request-one"), token)
    assert_response :accepted
    assert_not_equal id, response.parsed_body["id"]
  end

  test "health needs no authentication and reports counts" do
    OutboundMessage.create!(from_address: "sender@example.org", to_addresses: [ "recipient@example.net" ], status: "queued")
    Domain.create!(name: "example.net", active: false)
    get "/api/v1/health"
    assert_response :ok
    assert_equal({ "ok" => true, "version" => Mailroom::VERSION, "last_inbound_at" => nil,
      "queued_outbound" => 1, "domains" => 1 }, response.parsed_body)
  end
end
