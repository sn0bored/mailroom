# Integration tests run without Puma, so no request has an accepting socket. These stand-ins answer
# local_address the way the TCP socket Puma accepted would, and go where Puma puts it: env["puma.socket"].
# A real client cannot set that key, because request headers only reach the env as HTTP_*.
module Listeners
  Socket = Data.define(:address) do
    def self.tcp(port) = new(Addrinfo.tcp("127.0.0.1", port))
    def local_address = address
  end

  def self.internal = on(Socket.tcp(Mailroom.internal_port))
  def self.public = on(Socket.tcp(Mailroom.public_port))
  def self.none = on(nil)
  def self.on(socket) = { Mailroom::IngressGate::SOCKET => socket }

  # Every integration request arrives on the internal listener unless the test says otherwise.
  module DefaultToInternal
    def process(method, path, env: nil, **)
      super(method, path, env: Listeners.internal.merge(env || {}), **)
    end
  end
end

ActionDispatch::Integration::Session.prepend(Listeners::DefaultToInternal)
