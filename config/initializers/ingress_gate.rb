require "ipaddr"

module Mailroom
  # Defense in depth for the public side. Behind Tailscale, every request reaches Puma from
  # 127.0.0.1, so loopback alone proves nothing. A request counts as internal when it carries a
  # Tailscale identity header (Serve adds them, Funnel never does), when it arrived on the
  # tailnet-only port, when its Host is the machine itself, when a forwarded client IP is inside the
  # tailnet, or when MAILROOM_TRUST_LOCAL=1 (development only). Everything else may only reach the
  # Action Mailbox ingress and the health check.
  class IngressGate
    TAILNET = [ IPAddr.new("100.64.0.0/10"), IPAddr.new("fd7a:115c:a1e0::/48") ].freeze
    LOCAL_HOSTS = %w[localhost 127.0.0.1 [::1] ::1].freeze
    ALLOWED_PREFIXES = [ Mailroom::INGRESS_PATH_PREFIX, "/up" ].freeze
    INTERNAL_PORT = ENV.fetch("MAILROOM_SERVE_PORT", "8443")

    def initialize(app)
      @app = app
    end

    def call(env)
      request = Rack::Request.new(env)
      return @app.call(env) if internal?(request) || allowed_path?(request.path)
      [ 404, { "content-type" => "text/plain" }, [ "not found\n" ] ]
    end

    private

    def internal?(request)
      return true if Mailroom.trust_local?
      return true if request.get_header("HTTP_TAILSCALE_USER_LOGIN").present?
      host, port = request.host_with_port.to_s.split(":", 2)
      return true if port == INTERNAL_PORT
      return true if LOCAL_HOSTS.include?(host)
      ip = forwarded_ip(request)
      ip.present? && TAILNET.any? { |net| net.include?(ip) }
    end

    def allowed_path?(path)
      ALLOWED_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    end

    def forwarded_ip(request)
      raw = request.get_header("HTTP_X_FORWARDED_FOR").to_s.split(",").map(&:strip).reject(&:empty?).last
      raw.present? ? IPAddr.new(raw) : nil
    rescue IPAddr::Error
      nil
    end
  end
end

Rails.application.config.middleware.insert_before 0, Mailroom::IngressGate
