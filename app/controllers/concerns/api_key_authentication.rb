# Bearer <token> authentication for the agent and app surfaces. Tokens are looked up by digest.
module ApiKeyAuthentication
  extend ActiveSupport::Concern

  included do
    attr_reader :current_api_key
  end

  private

  def authenticate_api_key!
    token = request.authorization.to_s.delete_prefix("Bearer ").strip
    @current_api_key = ApiKey.authenticate(token)
    render json: { error: "unauthorized" }, status: :unauthorized unless @current_api_key
  end

  def require_scope!(scope)
    return true if current_api_key&.allows?(scope)
    render json: { error: "forbidden", reason: "scope", required: scope }, status: :forbidden
    false
  end
end
