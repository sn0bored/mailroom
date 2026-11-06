# Central place for the few runtime facts Mailroom needs. Everything comes from ENV;
# the settings table only holds values the app discovers for itself (the Postmark inbound hash,
# the generated instance id).
module Mailroom
  VERSION = "0.1.0"

  POSTMARK_INBOUND_DOMAIN = "inbound.postmarkapp.com"
  INGRESS_PATH_PREFIX = "/rails/action_mailbox/"

  def self.data_dir
    Pathname.new(ENV.fetch("MAILROOM_DATA_DIR") { Rails.env.production? ? File.expand_path("~/.mailroom") : Rails.root.join("storage").to_s })
  end

  def self.public_host = ENV["MAILROOM_PUBLIC_HOST"].presence
  def self.serve_host = ENV["MAILROOM_SERVE_HOST"].presence
  def self.forward_sender = ENV["MAILROOM_FORWARD_SENDER"].presence
  def self.forward_stream = ENV.fetch("MAILROOM_FORWARD_STREAM", "outbound")
  def self.default_forward_to = ENV["MAILROOM_DEFAULT_FORWARD_TO"].presence
  def self.trust_local? = ENV["MAILROOM_TRUST_LOCAL"] == "1"

  # Stamped on every outbound message so a copy that comes back is recognised as a loop.
  def self.instance_id
    ENV["MAILROOM_INSTANCE_ID"].presence || Setting.get("instance_id") || Setting.set("instance_id", SecureRandom.hex(8)).value
  end

  def self.inbound_address
    hash = Setting.get("inbound_hash")
    hash.present? ? "#{hash}@#{POSTMARK_INBOUND_DOMAIN}" : nil
  end
end
