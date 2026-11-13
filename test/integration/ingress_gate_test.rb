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
    [ :post, "/mcp" ], [ :get, "/mcp" ], [ :delete, "/mcp" ], [ :get, "/api/v1/health" ], [ :post, "/api/v1/send" ]
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

  test "the public listener checks the ingress password before Rails reads the body" do
    basic = ->(user, password) { ActionController::HttpAuthentication::Basic.encode_credentials(user, password) }
    # Not JSON at all: had Rails parsed it, this would be a 400, not a 401.
    [ nil, basic.("actionmailbox", "nope"), basic.("someone", "test-ingress-password"), "Bearer test-ingress-password",
      basic.("actionmailbox", "test-ingress-password").sub("Basic", "Digest") ].each do |authorization|
      post Mailroom::POSTMARK_INGRESS_PATH, params: "{not json", headers: { "Content-Type" => "application/json",
        "Authorization" => authorization }.compact, env: Listeners.public
      assert_response :unauthorized
      assert_equal "HTTP Basic: Access denied.\n", response.body
      assert_equal 'Basic realm="Action Mailbox"', response.headers["WWW-Authenticate"]
    end
    assert_equal 0, ActionMailbox::InboundEmail.count

    Domain.create!(name: "example.org")
    post Mailroom::POSTMARK_INGRESS_PATH, params: JSON.parse(file_fixture("postmark_inbound.json").read), as: :json,
         headers: { "Authorization" => basic.("actionmailbox", "test-ingress-password") }, env: Listeners.public
    assert_response :no_content
    assert_equal 1, ActionMailbox::InboundEmail.count
  end

  test "the public listener refuses everything when no ingress password is configured" do
    with_env("RAILS_INBOUND_EMAIL_PASSWORD" => nil) do
      post Mailroom::POSTMARK_INGRESS_PATH, params: "{}", headers: { "Content-Type" => "application/json",
        "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("actionmailbox", "") }, env: Listeners.public
      assert_response :unauthorized
    end
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

  test "the internal port on a non-loopback address gets the public rules" do
    # What `rails server -p MAILROOM_PORT` (0.0.0.0) sees for a connection from the LAN.
    [ "192.0.2.10", "10.0.0.5", "100.101.102.103", "2001:db8::1", "fd7a:115c:a1e0::1" ].each do |ip|
      get "/session/new", env: Listeners.on(Listeners::Socket.new(Addrinfo.tcp(ip, Mailroom.internal_port)))
      assert_gated
    end
  end

  test "the internal port on any loopback address reaches the app" do
    [ "127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1" ].each do |ip|
      get "/session/new", env: Listeners.on(Listeners::Socket.new(Addrinfo.tcp(ip, Mailroom.internal_port)))
      assert_response :success, ip
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

  test "headers can take internal access away, never grant it" do
    { "Tailscale-Funnel-Request" => "?1", "X-Forwarded-For" => "203.0.113.9" }.each do |name, value|
      get "/session/new", headers: { name => value }
      assert_gated
    end
    [ "100.101.102.103, 203.0.113.9", "198.51.100.7", "2001:db8::7", "not-an-address" ].each do |hops|
      get "/session/new", headers: { "X-Forwarded-For" => hops }
      assert_gated
    end
    get "/up", headers: { "Tailscale-Funnel-Request" => "?1" }
    assert_response :success
  end

  test "requests through Tailscale Serve or another private path stay internal" do
    # Serve replaces X-Forwarded-For with the tailnet client's address and never sends the Funnel header.
    [ "100.101.102.103", "fd7a:115c:a1e0::5", "203.0.113.9, 100.101.102.103", "127.0.0.1", "10.1.2.3",
      "172.16.0.9", "192.168.1.20", "fe80::1", "::ffff:192.168.1.20" ].each do |hops|
      get "/session/new", headers: { "X-Forwarded-For" => hops, "Tailscale-User-Login" => "owner@example.net" }
      assert_response :success, hops
    end
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

  test "a connection accepted on all interfaces through a LAN address is not internal" do
    lan = Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? && !a.ipv4_multicast? }
    skip "no non-loopback IPv4 address on this machine" unless lan
    listener = TCPServer.new("0.0.0.0", 0)
    port = listener.local_address.ip_port
    client = TCPSocket.new(lan.ip_address, port)
    accepted = listener.accept
    assert_equal lan.ip_address, accepted.local_address.ip_address
    assert_nil Mailroom::IngressGate.listener_port(Listeners.on(accepted))
  ensure
    client&.close
    accepted&.close
    listener&.close
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
