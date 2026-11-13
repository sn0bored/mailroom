require "ipaddr"
require "uri"

# Plain Ruby: config/puma.rb loads this before Rails boots.
module Mailroom
  # In production Puma must listen on exactly two loopback listeners, MAILROOM_PORT and
  # MAILROOM_PUBLIC_PORT. `rails server -p`, PORT or Thruster replace config/puma.rb's binds with a
  # single listener, often on every interface, which leaves the public tunnel nothing to point at.
  module ListenerCheck
    # binds: Puma bind URIs, configured or actually listening. Returns why they are wrong, or nil.
    def self.problem(binds, env = ENV)
      binds = Array(binds)
      expected = [ env.fetch("MAILROOM_PORT", "3100"), env["MAILROOM_PUBLIC_PORT"] ].map { |p| Integer(p.to_s, 10, exception: false) }
      ports = binds.map { |bind| loopback_port(bind) }
      return nil if expected.uniq.size == 2 && expected.none?(&:nil?) && ports.all? && ports.uniq.sort == expected.sort
      "Puma must listen on loopback at MAILROOM_PORT and MAILROOM_PUBLIC_PORT (#{expected.join(', ')}) and " \
        "nowhere else, not on #{binds.empty? ? 'nothing' : binds.join(', ')}. Start it with bin/mailroom-server."
    end

    # The port of a tcp:// bind on a loopback address, else nil.
    def self.loopback_port(bind)
      uri = URI.parse(bind.to_s)
      return nil unless uri.scheme == "tcp" && uri.port
      IPAddr.new(uri.host.to_s.delete("[]")).loopback? ? uri.port : nil
    rescue URI::Error, IPAddr::Error
      nil
    end

    # A listening socket as a bind URI, for checking what Puma actually opened.
    def self.bind_for(io)
      address = io.local_address
      return "unix://#{address.unix_path}" if address.unix?
      host = address.ipv6? ? "[#{address.ip_address}]" : address.ip_address
      "tcp://#{host}:#{address.ip_port}"
    end
  end
end
