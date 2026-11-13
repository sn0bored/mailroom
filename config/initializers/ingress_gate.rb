require "base64"
require "ipaddr"

module Mailroom
  # Decides what a request may reach by the listener that accepted its connection. Puma runs two
  # loopback listeners (config/puma.rb) and puts the accepted socket in env["puma.socket"] for every
  # request on the connection; its local address says which listener it was. A client cannot set that
  # key, because request headers only reach the env as HTTP_*.
  #
  # A request is internal only when its connection was accepted on 127.0.0.1 or ::1 at MAILROOM_PORT.
  # A listener on any other address (say, `rails server -p` binding 0.0.0.0) never counts as internal.
  # Headers can only take access away: a request that Tailscale Funnel forwarded, or whose nearest
  # X-Forwarded-For hop is a public address, gets the public rules even on the internal port. That
  # catches a public proxy pointed at the wrong port. No header can make a request internal.
  #
  # The public rules: GET or HEAD /up, and POST to the Postmark ingress with the ingress password.
  # The password is checked here, before Rails parses or logs the body. Everything else is a 404.
  class IngressGate
    SOCKET = "puma.socket".freeze
    INGRESS_USER = "actionmailbox".freeze
    PUBLIC_ROUTES = {
      [ "GET", "/up" ] => :open,
      [ "HEAD", "/up" ] => :open,
      [ "POST", Mailroom::POSTMARK_INGRESS_PATH ] => :ingress
    }.freeze
    # Set by Tailscale on every request it forwards from Funnel, and stripped from tailnet requests.
    FUNNEL_HEADER = "HTTP_TAILSCALE_FUNNEL_REQUEST".freeze
    # Addresses a private path may forward for: loopback, RFC 1918, link-local, IPv6 ULA (which holds
    # the Tailscale range fd7a:115c:a1e0::/48) and Tailscale's 100.64.0.0/10.
    CGNAT = IPAddr.new("100.64.0.0/10").freeze
    # Tailscale and the usual reverse proxies send X-Forwarded-For, never these, so only a client would.
    # They are dropped so no client picks the address Rails logs, audits and rate-limits by (Rack prefers
    # Forwarded over X-Forwarded-For), and so Client-IP disagreeing with X-Forwarded-For cannot trip
    # Rails' IP spoofing check, which raises in the request logger, outside the error pages: a bare 500.
    CLIENT_CHOSEN_ADDRESS = %w[HTTP_CLIENT_IP HTTP_FORWARDED].freeze

    # The port the request's connection was accepted on, when that was a loopback address; else nil.
    def self.listener_port(env)
      socket = env[SOCKET]
      socket = socket.to_io if socket.respond_to?(:to_io) # an SSL listener wraps the TCP socket
      return nil unless socket.respond_to?(:local_address)
      address = socket.local_address
      host = address.ipv6_v4mapped? ? address.ipv6_to_ipv4 : address # a dual-stack :: listener
      host.ipv4_loopback? || host.ipv6_loopback? ? address.ip_port : nil
    rescue StandardError
      nil
    end

    def self.private_address?(value)
      ip = IPAddr.new(value.to_s.strip).native
      ip.loopback? || ip.private? || ip.link_local? || CGNAT.include?(ip)
    rescue IPAddr::Error
      false
    end

    def initialize(app)
      @app = app
    end

    # The 404 for a public request that arrived on the internal listener says so, so an operator can tell
    # from outside that the tunnel or proxy points at the wrong port. It grants nothing.
    MISROUTED = "not found: a public request reached the internal listener\n".freeze

    def call(env)
      CLIENT_CHOSEN_ADDRESS.each { |key| env.delete(key) }
      return @app.call(env) if Mailroom.trust_local?
      on_internal = internal_listener?(env)
      return @app.call(env) if on_internal && !forwarded_from_public?(env)
      case PUBLIC_ROUTES[[ env["REQUEST_METHOD"], env["PATH_INFO"] ]]
      when :open then @app.call(env)
      when :ingress then ingress_authorized?(env) ? @app.call(env) : unauthorized
      else not_found(on_internal ? MISROUTED : "not found\n")
      end
    end

    private

    def internal_listener?(env)
      internal = Mailroom.internal_port
      return false if internal.nil? || internal == Mailroom.public_port
      self.class.listener_port(env) == internal
    end

    def forwarded_from_public?(env)
      return true if env.key?(FUNNEL_HEADER)
      hop = env["HTTP_X_FORWARDED_FOR"].to_s.split(",").map(&:strip).reject(&:empty?).last
      hop.present? && !self.class.private_address?(hop)
    end

    # Mirrors Action Mailbox's own check (ActionMailbox::BaseController#authenticate_by_password).
    def ingress_authorized?(env)
      password = Mailroom.ingress_password
      scheme, encoded = env["HTTP_AUTHORIZATION"].to_s.split(" ", 2)
      return false if password.blank? || !scheme.to_s.casecmp?("basic")
      user, given = Base64.decode64(encoded.to_s).split(":", 2)
      ActiveSupport::SecurityUtils.secure_compare(user.to_s, INGRESS_USER) &
        ActiveSupport::SecurityUtils.secure_compare(given.to_s, password)
    end

    def not_found(body) = [ 404, { "content-type" => "text/plain" }, [ body ] ]

    def unauthorized
      [ 401, { "content-type" => "text/plain", "www-authenticate" => 'Basic realm="Action Mailbox"' },
        [ "HTTP Basic: Access denied.\n" ] ]
    end
  end
end

Rails.application.config.middleware.insert_before 0, Mailroom::IngressGate
