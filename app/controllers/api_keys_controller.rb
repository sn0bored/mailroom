class ApiKeysController < ApplicationController
  def index
    @api_keys = ApiKey.order(created_at: :desc)
  end

  def new
    @api_key = ApiKey.new
  end

  def create
    attributes = params.require(:api_key).permit(:name, :allowed_from_domains, scopes: [])
    @api_key, @plaintext = ApiKey.generate(name: attributes[:name], scopes: Array(attributes[:scopes]).reject(&:blank?),
      allowed_from_domains: attributes[:allowed_from_domains].to_s.split(",").map(&:strip).reject(&:blank?))
    response.headers["Cache-Control"] = "no-store"
    render :created, status: :created
  rescue ActiveRecord::RecordInvalid => error
    @api_key = error.record
    render :new, status: :unprocessable_entity
  end

  def destroy
    ApiKey.find(params[:id]).revoke!
    redirect_to api_keys_path, notice: "API key revoked."
  end
end
