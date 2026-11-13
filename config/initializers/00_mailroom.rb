# Central place for the few runtime facts Mailroom needs. Everything comes from ENV;
# the settings table only holds values the app discovers for itself (the Postmark inbound hash,
# the generated instance id).
module Mailroom
  VERSION = "0.1.0"

  POSTMARK_INBOUND_DOMAIN = "inbound.postmarkapp.com"
  INGRESS_PATH_PREFIX = "/rails/action_mailbox/"
  # The only ingress route the public listener serves (Action Mailbox's Postmark endpoint).
  POSTMARK_INGRESS_PATH = "#{INGRESS_PATH_PREFIX}postmark/inbound_emails".freeze

  def self.data_dir
    Pathname.new(ENV.fetch("MAILROOM_DATA_DIR") { Rails.env.production? ? File.expand_path("~/.mailroom") : Rails.root.join("storage").to_s })
  end

  def self.public_host = ENV["MAILROOM_PUBLIC_HOST"].presence
  def self.serve_host = ENV["MAILROOM_SERVE_HOST"].presence
  def self.forward_sender = ENV["MAILROOM_FORWARD_SENDER"].presence || Setting.get("forward_sender").presence
  def self.forward_stream = ENV.fetch("MAILROOM_FORWARD_STREAM", "outbound")
  def self.default_forward_to = ENV["MAILROOM_DEFAULT_FORWARD_TO"].presence

  # Puma's two loopback listeners (config/puma.rb). The internal one carries the owner UI, MCP and API;
  # the public one carries only the webhook and /up. Mailroom::IngressGate tells them apart by port.
  def self.internal_port = parse_port(ENV.fetch("MAILROOM_PORT", "3100"))
  def self.public_port = parse_port(ENV["MAILROOM_PUBLIC_PORT"])

  def self.parse_port(value)
    port = Integer(value.to_s.strip, 10, exception: false)
    port if port&.between?(1, 65_535)
  end

  # The Action Mailbox ingress password, looked up the way Action Mailbox looks it up.
  def self.ingress_password(env = ENV)
    Rails.application.credentials.dig(:action_mailbox, :ingress_password) || env["RAILS_INBOUND_EMAIL_PASSWORD"]
  end

  # Development and test only: treat every request as internal. Production refuses to boot with it set
  # (config/initializers/preflight.rb), and any other environment ignores it.
  def self.trust_local? = Rails.env.local? && ENV["MAILROOM_TRUST_LOCAL"] == "1"

  # authserv-ids whose Authentication-Results header decides the sender check: normally the registrar
  # forwarder in front of Postmark, which checks the real sender before forwarding. Postmark writes none.
  def self.trusted_authserv_ids
    ENV.fetch("MAILROOM_TRUSTED_AUTHSERV_IDS", "").split(",").map { |id| id.strip.downcase }.reject(&:empty?)
  end

  # True when outbound mail can actually leave: a Postmark token in production, or the test delivery method.
  def self.sending_configured?
    ENV["POSTMARK_SERVER_TOKEN"].present? || ActionMailer::Base.delivery_method == :test
  end

  # Names this install; also salts the loop marker key (see LoopMarker).
  def self.instance_id
    ENV["MAILROOM_INSTANCE_ID"].presence || Setting.get("instance_id") || Setting.set("instance_id", SecureRandom.hex(8)).value
  end

  def self.inbound_address
    hash = Setting.get("inbound_hash")
    hash.present? ? "#{hash}@#{POSTMARK_INBOUND_DOMAIN}" : nil
  end
end
