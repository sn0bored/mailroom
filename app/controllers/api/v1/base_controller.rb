module Api
  module V1
    class BaseController < ActionController::API
      include ApiKeyAuthentication
      before_action :authenticate_api_key!

      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { error: "invalid", details: error.record.errors.full_messages }, status: :unprocessable_entity
      end
      rescue_from Outbound::Send::NotAllowed do |error|
        render json: { error: "forbidden", reason: error.message }, status: :forbidden
      end
      rescue_from ActionController::ParameterMissing do
        render json: { error: "missing_parameter" }, status: :bad_request
      end
    end
  end
end
