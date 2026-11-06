# Refuse to boot in production with the secrets that make the ingress safe missing.
# A webhook endpoint with no password would accept mail from anyone.
if Rails.env.production?
  missing = %w[SECRET_KEY_BASE RAILS_INBOUND_EMAIL_PASSWORD].select { |k| ENV[k].blank? }
  if missing.any?
    abort "Mailroom refuses to start: #{missing.join(', ')} not set. See .env.example."
  end
end
