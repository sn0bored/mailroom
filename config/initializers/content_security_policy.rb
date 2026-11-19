# A strict Content-Security-Policy for the owner UI. Mail content is rendered escaped, and this is the
# second line: nothing loads from anywhere but this app, nothing gets framed, and the only inline code
# is what Rails itself emits (the importmap and Turbo's progress-bar style), which carries a nonce.
# The nonce follows the session rather than the request so Turbo Drive visits, which keep the first
# page's policy, still accept it. The favicon is a data: URL, hence img-src data:.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.connect_src :self
    policy.font_src :self
    policy.form_action :self
    policy.frame_ancestors :none
    policy.img_src :self, :data
    policy.object_src :none
    policy.script_src :self
    policy.style_src :self
  end

  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s.presence || SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
