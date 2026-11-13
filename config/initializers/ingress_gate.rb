module Mailroom
  # Decides what a request may reach by the listener that accepted its connection, and by nothing the
  # client sent. Puma runs two loopback listeners (config/puma.rb) and puts the accepted socket in
  # env["puma.socket"] for every request on the connection; its local port says which listener it was.
  #
  # Only a connection accepted on the internal listener (MAILROOM_PORT) reaches the whole app. The public
  # listener, an unknown listener and a request with no socket at all get the public rules: GET or HEAD
  # /up, and POST to the Postmark ingress, which checks its own password. Everything else is a 404.
  #
  # Host, X-Forwarded-*, Forwarded and Tailscale-* headers are ignored on purpose: a proxy that forwards
  # everything passes them through from the internet. So is SERVER_PORT, which Puma copies from Host.
  # "puma.socket" itself cannot be set by a client, because request headers only reach env as HTTP_*.
  class IngressGate
    SOCKET = "puma.socket".freeze
    PUBLIC_ROUTES = {
      "/up" => %w[GET HEAD].freeze,
      Mailroom::POSTMARK_INGRESS_PATH => %w[POST].freeze
    }.freeze

    # The local port of the socket that accepted this request's connection, or nil when there is no
    # TCP socket to ask.
    def self.listener_port(env)
      socket = env[SOCKET]
      socket = socket.to_io if socket.respond_to?(:to_io) # an SSL listener wraps the TCP socket
      return nil unless socket.respond_to?(:local_address)
      address = socket.local_address
      address.ip? ? address.ip_port : nil
    rescue StandardError
      nil
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if internal?(env) || public_route?(env)
      [ 404, { "content-type" => "text/plain" }, [ "not found\n" ] ]
    end

    private

    def internal?(env)
      return true if Mailroom.trust_local?
      internal = Mailroom.internal_port
      return false if internal.nil? || internal == Mailroom.public_port
      self.class.listener_port(env) == internal
    end

    def public_route?(env)
      PUBLIC_ROUTES.fetch(env["PATH_INFO"], []).include?(env["REQUEST_METHOD"])
    end
  end
end

Rails.application.config.middleware.insert_before 0, Mailroom::IngressGate
