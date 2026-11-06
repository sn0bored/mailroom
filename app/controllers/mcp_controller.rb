# JSON-RPC 2.0 over HTTP (MCP protocol 2025-03-26), POST only. Bearer API key on every request.
# Tools the key's scopes do not allow are invisible in tools/list and rejected in tools/call.
class McpController < ActionController::API
  include ApiKeyAuthentication

  PROTOCOL_VERSION = "2025-03-26".freeze

  before_action :authenticate_api_key!

  def handle
    payload = JSON.parse(request.raw_post.presence || "{}")
    if payload.is_a?(Array)
      responses = payload.filter_map { |req| respond_to_request(req) }
      render json: responses
    else
      response_body = respond_to_request(payload)
      response_body ? render(json: response_body) : head(:accepted)
    end
  rescue JSON::ParserError
    render json: rpc_error(nil, -32700, "parse error"), status: :bad_request
  end

  private

  def respond_to_request(req)
    id = req["id"]
    method = req["method"].to_s
    params = req["params"].is_a?(Hash) ? req["params"] : {}
    return nil if method.start_with?("notifications/")

    case method
    when "initialize"
      rpc_result(id, {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "mailroom", version: Mailroom::VERSION },
        instructions: Mcp::Frame::INSTRUCTIONS
      })
    when "ping"
      rpc_result(id, {})
    when "tools/list"
      rpc_result(id, { tools: registry.manifests_for(current_api_key) })
    when "tools/call"
      call_tool(id, params)
    else
      rpc_error(id, -32601, "method not found")
    end
  end

  def call_tool(id, params)
    tool = registry.lookup(params["name"])
    return rpc_error(id, -32601, "unknown tool") unless tool && tool.allowed?(current_api_key)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = tool.call(params["arguments"], current_api_key)
    rpc_result(id, result.merge(isError: false))
  rescue ArgumentError, ActiveRecord::RecordNotFound => e
    Audit.record("mcp.#{tool.tool_name}", actor: current_api_key, outcome: "rejected", error: e, ip: request.remote_ip)
    rpc_error(id, -32602, e.is_a?(ActiveRecord::RecordNotFound) ? "not found" : "invalid params")
  rescue StandardError => e
    Audit.record("mcp.#{tool&.tool_name || params['name']}", actor: current_api_key, outcome: "error", error: e, ip: request.remote_ip,
                 duration_ms: started && ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
    Rails.logger.error("[mcp] #{tool&.tool_name} failed: #{e.class}")
    rpc_result(id, { content: [ { type: "text", text: "tool failed: #{e.class.name}" } ], isError: true })
  end

  def registry = Mcp::ToolRegistry.instance
  def rpc_result(id, result) = { jsonrpc: "2.0", id: id, result: result }
  def rpc_error(id, code, message) = { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
end
