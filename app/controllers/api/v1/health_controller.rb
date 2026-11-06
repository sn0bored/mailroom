module Api
  module V1
    class HealthController < BaseController
      skip_before_action :authenticate_api_key!

      def show
        render json: { ok: true, version: Mailroom::VERSION,
          last_inbound_at: Message.maximum(:received_at),
          queued_outbound: OutboundMessage.where(status: "queued").count,
          domains: Domain.active.count }
      end
    end
  end
end
