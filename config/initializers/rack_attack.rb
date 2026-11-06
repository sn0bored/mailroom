# Throttles. Tokens are hashed before they become cache keys, so a raw token never lands in the cache.
class Rack::Attack
  self.cache.store = ActiveSupport::Cache::MemoryStore.new

  throttle("logins/ip", limit: 10, period: 5.minutes) do |req|
    req.ip if req.post? && req.path == "/session"
  end

  throttle("agent-and-api/ip", limit: 300, period: 5.minutes) do |req|
    req.ip if req.path.start_with?("/api/", "/mcp")
  end

  throttle("sends/key", limit: 60, period: 1.minute) do |req|
    if req.post? && req.path == "/api/v1/send"
      token = req.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Bearer ").strip
      Digest::SHA256.hexdigest(token) if token.present?
    end
  end

  self.throttled_responder = ->(_req) { [ 429, { "Content-Type" => "application/json" }, [ { error: "rate_limited" }.to_json ] ] }
end
