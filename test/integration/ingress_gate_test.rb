require "test_helper"

class IngressGateTest < ActionDispatch::IntegrationTest
  PUBLIC = { "Host" => "mailroom.example.ts.net" }.freeze

  test "public requests reach only the ingress and the health check" do
    get "/up", headers: PUBLIC
    assert_response :success

    get "/session/new", headers: PUBLIC
    assert_response :not_found
    assert_equal "not found\n", response.body

    post "/mcp", headers: PUBLIC
    assert_response :not_found
  end

  test "the tailnet port, identity headers, local hosts and tailnet clients are internal" do
    get "/session/new", headers: { "Host" => "mailroom.example.ts.net:8443" }
    assert_response :success

    get "/session/new", headers: PUBLIC.merge("Tailscale-User-Login" => "owner@example.net")
    assert_response :success

    get "/session/new", headers: { "Host" => "localhost" }
    assert_response :success

    get "/session/new", headers: PUBLIC.merge("X-Forwarded-For" => "203.0.113.9, 100.101.102.103")
    assert_response :success

    post "/mcp", headers: { "Host" => "localhost" }
    assert_response :unauthorized, "reached the app, which asked for a key"
  end
end
