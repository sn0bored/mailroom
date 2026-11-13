module Mailroom
  # Production boot checks. Each problem is a reason to refuse to start.
  module Preflight
    MIN_INGRESS_PASSWORD = 32

    def self.problems(env = ENV)
      password = Mailroom.ingress_password(env)
      [
        ("SECRET_KEY_BASE not set" if env["SECRET_KEY_BASE"].blank?),
        ("RAILS_INBOUND_EMAIL_PASSWORD not set" if password.blank?),
        ("RAILS_INBOUND_EMAIL_PASSWORD is shorter than #{MIN_INGRESS_PASSWORD} characters" if password.present? && password.length < MIN_INGRESS_PASSWORD),
        *listener_problems(env)
      ].compact
    end

    # The public tunnel or proxy must have a listener of its own, or Mailroom::IngressGate has nothing
    # to tell apart. MAILROOM_TRUST_LOCAL would make every request internal, so it is refused outright
    # rather than ignored: an operator who set it believes something about the deployment that is false.
    def self.listener_problems(env)
      internal = Mailroom.parse_port(env.fetch("MAILROOM_PORT", "3100"))
      public_port = Mailroom.parse_port(env["MAILROOM_PUBLIC_PORT"])
      [
        ("MAILROOM_PORT is not a valid port" unless internal),
        ("MAILROOM_PUBLIC_PORT is not set" if env["MAILROOM_PUBLIC_PORT"].blank?),
        ("MAILROOM_PUBLIC_PORT is not a valid port" if env["MAILROOM_PUBLIC_PORT"].present? && public_port.nil?),
        ("MAILROOM_PUBLIC_PORT must differ from MAILROOM_PORT" if internal && internal == public_port),
        ("MAILROOM_TRUST_LOCAL is for development only; remove it" if env["MAILROOM_TRUST_LOCAL"] == "1")
      ].compact
    end
  end
end

# Refuse to boot in production without the secrets that make the ingress safe, or without the separate
# public listener that keeps everything else off the internet.
if Rails.env.production? && (problems = Mailroom::Preflight.problems).any?
  abort "Mailroom refuses to start: #{problems.join('; ')}. See .env.example."
end
