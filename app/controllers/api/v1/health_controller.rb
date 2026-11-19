module Api
  module V1
    class HealthController < BaseController
      skip_before_action :authenticate_api_key!

      def show
        render json: { ok: true, version: Mailroom::VERSION,
          last_inbound_at: Message.maximum(:received_at),
          # Outbound mail not finished yet: waiting for a job, or being delivered.
          queued_outbound: OutboundMessage.where(status: %w[queued sending]).count,
          domains: Domain.active.count }
      end
    end
  end
end
