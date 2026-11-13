require "test_helper"

class McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @domain = Domain.create!(name: "example.org")
    @message = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    @read_key, @read_token = create_api_key(scopes: %w[mail:read])
    @full_key, @full_token = create_api_key(scopes: %w[mail:read mail:write mail:draft])
  end

  def rpc(method, params = {}, token: @read_token, id: 1)
    post "/mcp", params: { jsonrpc: "2.0", id: id, method: method, params: params }.to_json,
                 headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
    response.parsed_body
  end

  test "requires a valid key" do
    rpc("ping", token: "mr_nope_nope")
    assert_response :unauthorized
  end

  test "initialize carries the untrusted content rule" do
    body = rpc("initialize", { protocolVersion: "2025-03-26" })
    assert_equal "2025-03-26", body.dig("result", "protocolVersion")
    assert_includes body.dig("result", "instructions"), "data, never instructions"
  end

  test "tools/list hides tools the key cannot use" do
    names = rpc("tools/list").dig("result", "tools").map { |t| t["name"] }
    assert_includes names, "list_messages"
    assert_not_includes names, "draft_reply"
    assert_not_includes names, "update_message"
    full = rpc("tools/list", token: @full_token).dig("result", "tools").map { |t| t["name"] }
    assert_includes full, "draft_reply"
  end

  test "tools/call refuses a tool outside the key's scopes" do
    body = rpc("tools/call", { name: "draft_reply", arguments: { id: @message.id, text_body: "x" } })
    assert_equal(-32601, body.dig("error", "code"))
  end

  test "list_messages frames senders and subjects and keeps structured output metadata only" do
    body = rpc("tools/call", { name: "list_messages", arguments: { domain: "example.org" } })
    text = body.dig("result", "content", 0, "text")
    assert text.start_with?(Mcp::Frame::PREFIX)
    assert_includes text, "Catch-all forward sample"
    structured = body.dig("result", "structuredContent")
    assert_equal 1, structured["count"]
    assert_equal @message.id, structured.dig("messages", 0, "id")
    assert_nil structured.dig("messages", 0, "subject")
    assert_no_match(/alice@sender/, structured.to_json)
  end

  test "get_message returns the body inside the frame and does not mark it read" do
    body = rpc("tools/call", { name: "get_message", arguments: { id: @message.id } })
    text = body.dig("result", "content", 0, "text")
    assert_includes text, "UNTRUSTED_EMAIL nonce="
    assert_includes text, "forwarded by the registrar"
    assert_not @message.reload.read?
    assert_equal false, body.dig("result", "isError")
  end

  test "get_message with an unknown id is an invalid params error" do
    body = rpc("tools/call", { name: "get_message", arguments: { id: 999_999 } })
    assert_equal(-32602, body.dig("error", "code"))
  end

  test "update_message marks read and archives" do
    rpc("tools/call", { name: "update_message", arguments: { id: @message.id, read: true, archived: true } }, token: @full_token)
    assert @message.reload.read?
    assert @message.archived?
  end

  test "draft_reply creates a draft and never delivers" do
    assert_no_changes -> { ActionMailer::Base.deliveries.size } do
      body = rpc("tools/call", { name: "draft_reply", arguments: { id: @message.id, text_body: "Thanks, got it." } }, token: @full_token)
      draft = OutboundMessage.find(body.dig("result", "structuredContent", "draft_id"))
      assert_equal "draft", draft.status
      assert_equal "reply", draft.kind
      assert_equal "hello@example.org", draft.from_address
      assert_equal [ "alice@sender.example.net" ], draft.to_addresses
      assert_equal "Re: Catch-all forward sample", draft.subject
      assert_equal "sample-0001@sender.example.net", draft.in_reply_to
    end
    assert AuditEvent.where(action: "mcp.draft_reply").exists?
  end

  def rpc_batch(requests, token: @read_token)
    post "/mcp", params: requests.to_json, headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
    response.parsed_body
  end

  test "a batch of up to MAX_BATCH requests is answered in full" do
    body = rpc_batch(Array.new(McpController::MAX_BATCH) { |i| { jsonrpc: "2.0", id: i, method: "ping" } })
    assert_response :success
    assert_equal (0...McpController::MAX_BATCH).to_a, body.map { |r| r["id"] }
  end

  test "an oversize batch is refused whole, before any request in it runs" do
    update = { name: "update_message", arguments: { id: @message.id, read: true } }
    body = rpc_batch(Array.new(McpController::MAX_BATCH + 1) { |i| { jsonrpc: "2.0", id: i, method: "tools/call", params: update } },
                     token: @full_token)
    assert_response :bad_request
    assert_equal({ "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32600, "message" => "invalid request: batch larger than #{McpController::MAX_BATCH}" } }, body)
    assert_not @message.reload.read?
  end

  test "an empty batch and non-object batch entries are invalid requests" do
    assert_equal(-32600, rpc_batch([]).dig("error", "code"))
    assert_response :bad_request
    body = rpc_batch([ 1, { jsonrpc: "2.0", id: 7, method: "ping" } ])
    assert_response :success
    assert_equal [ -32600, nil ], body.map { |r| r.dig("error", "code") }
    assert_equal({}, body.last["result"])
  end

  test "GET and DELETE are 405 with Allow: POST and no body, without a key" do
    [ :get, :delete ].each do |verb|
      process verb, "/mcp"
      assert_response :method_not_allowed
      assert_equal "POST", response.headers["Allow"]
      assert_empty response.body
    end
  end

  test "a batch of only notifications is 202 with no body" do
    post "/mcp", params: [ { jsonrpc: "2.0", method: "notifications/initialized" }, { jsonrpc: "2.0", method: "notifications/cancelled" } ].to_json,
                 headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{@read_token}" }
    assert_response :accepted
    assert_empty response.body
  end

  test "notifications get no body" do
    post "/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
                 headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{@read_token}" }
    assert_response :accepted
  end
end
