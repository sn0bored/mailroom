require "net/http"
require "json"

# Everything Mailroom needs from Postmark with a server token only: point the inbound webhook at us,
# turn raw email on, learn the inbound address, and retry inbound messages Postmark gave up on.
class PostmarkSetup
  API = "https://api.postmarkapp.com".freeze

  def initialize(token: ENV["POSTMARK_SERVER_TOKEN"], client: nil, http: nil)
    @token = token
    @client = client
    @http = http
  end

  def configure!(public_host: Mailroom.public_host, password: ENV["RAILS_INBOUND_EMAIL_PASSWORD"])
    raise ArgumentError, "POSTMARK_SERVER_TOKEN is not set" if @token.blank?
    raise ArgumentError, "MAILROOM_PUBLIC_HOST is not set" if public_host.blank?
    raise ArgumentError, "RAILS_INBOUND_EMAIL_PASSWORD is not set" if password.blank?

    hook = "https://actionmailbox:#{password}@#{public_host}#{Mailroom::INGRESS_PATH_PREFIX}postmark/inbound_emails"
    client.update_server_info(inbound_hook_url: hook, raw_email_enabled: true,
      inbound_spam_threshold: Setting.get("inbound_spam_threshold").to_f)
    info = client.server_info
    Setting.set("inbound_hash", info[:inbound_hash].to_s)
    Setting.set("postmark_server_id", info[:id].to_s)
    { inbound_address: Mailroom.inbound_address, server_id: info[:id], server_name: info[:name], public_host: public_host }
  end

  # Postmark retries a failing webhook for about ten hours, then parks the message as "Inbound Error".
  # This asks for every parked message again; run it hourly and after any outage.
  def retry_failed!(count: 100)
    raise ArgumentError, "POSTMARK_SERVER_TOKEN is not set" if @token.blank?
    listing = request(:get, "/messages/inbound?count=#{count}&offset=0&status=failed")
    ids = Array(listing["InboundMessages"]).map { |m| m["MessageID"] }.compact
    retried = ids.count { |id| request(:put, "/messages/inbound/#{id}/retry")["ErrorCode"].to_i.zero? }
    { failed: ids.size, retried: retried }
  end

  private

  def client
    @client ||= Postmark::ApiClient.new(@token)
  end

  def request(method, path)
    return @http.call(method, path) if @http
    uri = URI("#{API}#{path}")
    req = (method == :get ? Net::HTTP::Get : Net::HTTP::Put).new(uri)
    req["Accept"] = "application/json"
    req["Content-Type"] = "application/json"
    req["X-Postmark-Server-Token"] = @token
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    JSON.parse(res.body.presence || "{}")
  end
end
