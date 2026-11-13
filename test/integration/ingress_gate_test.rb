require "test_helper"
require "socket"

class IngressGateTest < ActionDispatch::IntegrationTest
  # Everything the old gate trusted. None of it may turn a public-listener request into an internal one.
  SPOOFS = {
    "Host" => "localhost",
    "X-Forwarded-Host" => "localhost",
    "Forwarded" => "for=100.101.102.103;host=localhost",
    "Tailscale-User-Login" => "owner@example.net",
    "X-Forwarded-For" => "203.0.113.9, 100.101.102.103",
    "X-Forwarded-Port" => "3100",
    "Puma-Socket" => "127.0.0.1:3100"
  }.freeze

  BLOCKED = [
    [ :get, "/upload" ], [ :get, "/upx" ], [ :get, "/up/" ], [ :get, "/up.json" ], [ :post, "/up" ],
    [ :get, Mailroom::POSTMARK_INGRESS_PATH ],
    [ :post, "/rails/action_mailbox/relay/inbound_emails" ],
    [ :post, "/rails/action_mailbox/mailgun/inbound_emails/mime" ],
    [ :get, "/rails/action_mailbox/conductor/inbound_emails" ],
    [ :get, "/rails/conductor/action_mailbox/inbound_emails" ],
    [ :post, "/rails/active_storage/direct_uploads" ],
    [ :get, "/rails/active_storage/blobs/redirect/x/file.txt" ],
    [ :get, "/session/new" ], [ :post, "/session" ], [ :get, "/" ],
    [ :post, "/mcp" ], [ :get, "/mcp" ], [ :get, "/api/v1/health" ], [ :post, "/api/v1/send" ]
  ].freeze

  def assert_gated
    assert_response :not_found
    assert_equal "not found\n", response.body
  end

  test "the public listener serves exactly /up" do
    get "/up", env: Listeners.public
    assert_response :success
    head "/up", env: Listeners.public
    assert_response :success
  end

  test "the public listener passes the Postmark ingress to its own password check" do
    post Mailroom::POSTMARK_INGRESS_PATH, params: { RawEmail: "x" }, as: :json, env: Listeners.public
    assert_response :unauthorized

    Domain.create!(name: "example.org")
    auth = ActionController::HttpAuthentication::Basic.encode_credentials("actionmailbox", "test-ingress-password")
    post Mailroom::POSTMARK_INGRESS_PATH, params: JSON.parse(file_fixture("postmark_inbound.json").read), as: :json,
         headers: { "Authorization" => auth }, env: Listeners.public
    assert_response :no_content
  end

  test "everything else is not found on the public listener" do
    BLOCKED.each do |verb, path|
      process verb, path, env: Listeners.public
      assert_gated
    end
  end

  test "spoofed headers leave a public-listener request public" do
    SPOOFS.each do |name, value|
      get "/session/new", headers: { name => value }, env: Listeners.public
      assert_gated
    end
    get "/session/new", headers: SPOOFS.merge("Host" => "mailroom.example.net:8443"), env: Listeners.public
    assert_gated
    get "/session/new", headers: { "Host" => "localhost:3100" }, env: Listeners.public
    assert_gated
  end

  test "a request without socket information gets the public rules" do
    get "/session/new", env: Listeners.none
    assert_gated
    get "/session/new", headers: SPOOFS, env: Listeners.none
    assert_gated
    get "/up", env: Listeners.none
    assert_response :success
  end

  test "an unknown listener gets the public rules" do
    [ Listeners::Socket.tcp(9999), Listeners::Socket.new(Addrinfo.unix("/nonexistent/puma.sock")), Object.new ].each do |socket|
      get "/session/new", env: Listeners.on(socket)
      assert_gated
    end
  end

  test "the internal listener reaches the app" do
    get "/session/new"
    assert_response :success
    get "/api/v1/health"
    assert_response :success
    post "/mcp"
    assert_response :unauthorized, "reached the app, which asked for a key"
  end

  test "nothing is internal when both listeners share a port" do
    with_env("MAILROOM_PUBLIC_PORT" => ENV["MAILROOM_PORT"]) do
      get "/session/new"
      assert_gated
    end
  end

  test "MAILROOM_TRUST_LOCAL works in development and test only" do
    original = Rails.env
    with_env("MAILROOM_TRUST_LOCAL" => "1") do
      get "/session/new", env: Listeners.public
      assert_response :success

      Rails.env = "production"
      assert_not Mailroom.trust_local?
    end
  ensure
    Rails.env = original
  end

  test "an accepted TCP socket reports the port of the listener that accepted it" do
    listeners = Array.new(2) { TCPServer.new("127.0.0.1", 0) }
    listeners.each do |listener|
      port = listener.local_address.ip_port
      client = TCPSocket.new("127.0.0.1", port)
      accepted = listener.accept
      assert_equal port, Mailroom::IngressGate.listener_port(Listeners.on(accepted))
    ensure
      client&.close
      accepted&.close
    end
  ensure
    listeners&.each(&:close)
  end

  test "the public ingress path is Action Mailbox's Postmark route" do
    assert_equal Rails.application.routes.url_helpers.rails_postmark_inbound_emails_path, Mailroom::POSTMARK_INGRESS_PATH
    assert Mailroom::POSTMARK_INGRESS_PATH.start_with?(Mailroom::INGRESS_PATH_PREFIX)
  end

  private

  def with_env(values)
    saved = values.keys.index_with { |k| ENV[k] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
