require "test_helper"
require_relative "../../../support/outbound_stubs"
using OutboundStubs

class ApiSendControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @domain = Domain.create!(name: "example.org", send_enabled: true)
    @key, @token = ApiKey.generate(name: "Test", scopes: [ "mail:send" ], allowed_from_domains: [ "example.org" ])
    @payload = { from: "sender@example.org", to: "recipient@example.net", subject: "Test", text: "Body" }
    ActionMailer::Base.deliveries.clear
  end

  def send_request(payload = @payload, token = @token)
    post "/api/v1/send", params: payload, headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  def status_request(id, token = @token)
    get "/api/v1/send/#{id}", headers: { "Authorization" => "Bearer #{token}" }
  end

  # Render unexpected exceptions as the 500 a client would get, instead of raising into the test.
  def with_rendered_exceptions
    env_config = Rails.application.env_config
    original = env_config["action_dispatch.show_exceptions"]
    env_config["action_dispatch.show_exceptions"] = :all
    yield
  ensure
    env_config["action_dispatch.show_exceptions"] = original
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
    assert_equal "queued", response.parsed_body["status"]
    assert_equal true, response.parsed_body["idempotent"]
  end

  test "a replay during a failing enqueue reports in progress" do
    replay = open_session
    payload = @payload.merge(idempotency_key: "pending-one")
    queue_down = ->(*) do
      replay.post "/api/v1/send", params: payload,
        headers: { "Authorization" => "Bearer #{@token}" }, as: :json
      raise SolidQueue::Job::EnqueueError, "queue down"
    end
    OutboundDeliveryJob.stub(:perform_later, queue_down) do
      with_rendered_exceptions do
        assert_no_difference("OutboundMessage.count") { send_request(payload) }
      end
    end
    assert_response :internal_server_error
    assert_equal 409, replay.response.status
    assert_equal({ "error" => "in_progress" }, replay.response.parsed_body)
    assert_no_enqueued_jobs
  end

  test "a replay is in progress before enqueue returns and idempotent after the stamp" do
    replay = open_session
    payload = @payload.merge(idempotency_key: "pending-one")
    enqueue = OutboundDeliveryJob.method(:perform_later)
    during_enqueue = ->(*args, &block) do
      replay.post "/api/v1/send", params: payload,
        headers: { "Authorization" => "Bearer #{@token}" }, as: :json
      enqueue.call(*args, &block)
    end
    OutboundDeliveryJob.stub(:perform_later, during_enqueue) do
      assert_enqueued_jobs(1, only: OutboundDeliveryJob) { send_request(payload) }
    end
    assert_response :accepted
    assert_equal 409, replay.response.status
    assert_equal({ "error" => "in_progress" }, replay.response.parsed_body)
    record = OutboundMessage.find(response.parsed_body["id"])
    assert_equal enqueued_jobs.last["job_id"], record.delivery_job_id

    assert_no_enqueued_jobs { send_request(payload) }
    assert_response :ok
    assert_equal record.id, response.parsed_body["id"]
    assert_equal true, response.parsed_body["idempotent"]
  end

  test "a concurrent key insertion is in progress until its enqueue is stamped" do
    race = ->(record, actor:) do
      record.dup.save!
      record.save!
    end
    Outbound::Send.stub(:call, race) do
      assert_no_enqueued_jobs { send_request(@payload.merge(idempotency_key: "racing-one")) }
    end
    assert_response :conflict
    assert_equal({ "error" => "in_progress" }, response.parsed_body)
  end

  test "a refused send leaves no row and no job" do
    @domain.update!(send_enabled: false)
    assert_no_difference "OutboundMessage.count" do
      assert_no_enqueued_jobs { send_request(@payload.merge(idempotency_key: "refused-one")) }
    end
    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body["error"]
  end

  test "a refused send retried with the same key is refused again" do
    @domain.update!(send_enabled: false)
    2.times do
      send_request(@payload.merge(idempotency_key: "refused-one"))
      assert_response :forbidden
      assert_nil response.parsed_body["idempotent"]
    end
    assert_not OutboundMessage.exists?(idempotency_key: "refused-one")
  end

  test "a refused send retried after the domain is enabled is queued" do
    @domain.update!(send_enabled: false)
    send_request(@payload.merge(idempotency_key: "retry-one"))
    assert_response :forbidden

    @domain.update!(send_enabled: true)
    assert_enqueued_jobs(1, only: OutboundDeliveryJob) { send_request(@payload.merge(idempotency_key: "retry-one")) }
    assert_response :accepted
    assert_equal "queued", response.parsed_body["status"]
    assert_nil response.parsed_body["idempotent"]
    assert_equal [ response.parsed_body["id"] ], OutboundMessage.where(idempotency_key: "retry-one").ids
  end

  test "a send whose enqueue fails is a 500 that leaves no row, and its retry is queued" do
    queue_down = ->(*) { raise SolidQueue::Job::EnqueueError, "ActiveRecord::StatementInvalid: database is locked" }
    OutboundDeliveryJob.stub(:perform_later, queue_down) do
      with_rendered_exceptions do
        assert_no_difference("OutboundMessage.count") { send_request(@payload.merge(idempotency_key: "queue-down")) }
      end
    end
    assert_response :internal_server_error
    assert_not AuditEvent.exists?(action: "api.send")

    assert_enqueued_jobs(1, only: OutboundDeliveryJob) { send_request(@payload.merge(idempotency_key: "queue-down")) }
    assert_response :accepted
    assert_equal "queued", response.parsed_body["status"]
    assert_nil response.parsed_body["idempotent"]
  end

  test "replaying the key of a message failed by the upgrade cleanup reports it as failed" do
    record = OutboundMessage.create!(kind: "api", api_key: @key, status: "failed", idempotency_key: "legacy-one",
      error: "refused before upgrade; not sent", from_address: "sender@example.org", to_addresses: [ "recipient@example.net" ])
    assert_no_enqueued_jobs { send_request(@payload.merge(idempotency_key: "legacy-one")) }
    assert_response :ok
    assert_equal({ "id" => record.id, "status" => "failed", "error" => "refused before upgrade; not sent", "idempotent" => true },
      response.parsed_body.slice("id", "status", "error", "idempotent"))
  end

  test "a display-name sender passes the domain check and keeps the name in the From header" do
    perform_enqueued_jobs(only: OutboundDeliveryJob) do
      send_request(@payload.merge(from: "Example Sender <sender@example.org>"))
    end
    assert_response :accepted
    record = OutboundMessage.find(response.parsed_body["id"])
    assert_equal "Example Sender <sender@example.org>", record.from_address
    assert_equal "sent", record.status
    delivery = ActionMailer::Base.deliveries.last
    assert_equal [ "sender@example.org" ], delivery.from
    assert_equal [ "Example Sender" ], delivery[:from].display_names
  end

  test "a display name does not get around the key's domain restriction" do
    Domain.create!(name: "example.net", send_enabled: true)
    send_request(@payload.merge(from: "Example Sender <sender@example.net>"))
    assert_response :forbidden
    assert_equal "key cannot send from this domain", response.parsed_body["reason"]
  end

  test "a from that is not exactly one address is invalid, not an error" do
    [ "garbage", "<<<@@@", "sender@example.org>", "sender@example.org, other@example.org",
      "group: sender@example.org;", "Name <sender@example.org>\r\nBcc: blind@example.net",
      [ "sender@example.org" ], { name: "sender@example.org" } ].each do |from|
      assert_no_difference("OutboundMessage.count") { send_request(@payload.merge(from: from)) }
      assert_response :unprocessable_entity, from.inspect
      assert_equal "invalid", response.parsed_body["error"]
    end
  end

  test "an idempotency key that is not a string is invalid" do
    [ { nested: "value" }, [ "value" ] ].each do |key|
      assert_no_difference("OutboundMessage.count") { send_request(@payload.merge(idempotency_key: key)) }
      assert_response :unprocessable_entity
    end
    send_request(@payload.merge(idempotency_key: 12345))
    assert_response :accepted
    assert_equal "12345", response.parsed_body["idempotency_key"]
  end

  test "status returns the key's own message in the same shape as the send response" do
    perform_enqueued_jobs(only: OutboundDeliveryJob) { send_request(@payload.merge(idempotency_key: "status-one")) }
    sent = response.parsed_body
    record = OutboundMessage.find(sent["id"])

    status_request(record.id)
    assert_response :ok
    body = response.parsed_body
    assert_equal sent.keys, body.keys
    assert_equal %w[created_at error id idempotency_key provider_message_id sent_at status], body.keys.sort
    assert_equal({ "id" => record.id, "status" => "sent", "idempotency_key" => "status-one", "error" => nil,
      "created_at" => record.created_at.utc.iso8601, "sent_at" => record.sent_at.utc.iso8601,
      "provider_message_id" => record.postmark_message_id }, body)
    assert record.postmark_message_id.present?
  end

  test "status reports a failed delivery's error class" do
    record = OutboundMessage.create!(kind: "api", api_key: @key, status: "failed", error: "ArgumentError",
      from_address: "sender@example.org", to_addresses: [ "recipient@example.net" ], text_body: "Private body")
    status_request(record.id)
    assert_response :ok
    assert_equal "failed", response.parsed_body["status"]
    assert_equal "ArgumentError", response.parsed_body["error"]
    assert_not_includes response.body, "Private body"
  end

  test "status of another key's message is not found" do
    send_request
    id = response.parsed_body["id"]
    _, other_token = ApiKey.generate(name: "Other", scopes: [ "mail:send" ])
    status_request(id, other_token)
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)
  end

  test "status needs the send scope" do
    send_request
    id = response.parsed_body["id"]
    @key.update!(scopes: [ "mail:read" ])
    status_request(id)
    assert_response :forbidden
    assert_equal "scope", response.parsed_body["reason"]
  end

  test "status of an unknown id or an agent draft is not found" do
    draft = OutboundMessage.create!(kind: "reply", status: "draft", api_key: @key,
      from_address: "sender@example.org", to_addresses: [ "recipient@example.net" ])
    [ 999_999, "not-a-number", draft.id ].each do |id|
      status_request(id)
      assert_response :not_found
    end
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
    %w[queued sending sent].each do |status|
      OutboundMessage.create!(from_address: "sender@example.org", to_addresses: [ "recipient@example.net" ], status: status)
    end
    Domain.create!(name: "example.net", active: false)
    get "/api/v1/health"
    assert_response :ok
    assert_equal({ "ok" => true, "version" => Mailroom::VERSION, "last_inbound_at" => nil,
      "queued_outbound" => 2, "domains" => 1 }, response.parsed_body)
  end
end
