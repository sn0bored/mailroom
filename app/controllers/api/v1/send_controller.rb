module Api
  module V1
    class SendController < BaseController
      def create
        return unless require_scope!("mail:send")

        key = params[:idempotency_key].presence
        existing = current_api_key.outbound_messages.find_by(idempotency_key: key) if key
        return render_record(existing, replay: true) if existing

        record = OutboundMessage.create!(kind: "api", api_key: current_api_key,
          from_address: params[:from], to_addresses: Array(params[:to]),
          cc_addresses: Array(params[:cc]), bcc_addresses: Array(params[:bcc]),
          subject: params[:subject], text_body: params[:text], html_body: params[:html],
          reply_to: params[:reply_to], in_reply_to: params[:in_reply_to], idempotency_key: key)
        Outbound::Send.call(record, actor: current_api_key)
        Audit.record("api.send", actor: current_api_key, target: record, ip: request.remote_ip)
        render_record(record)
      rescue ActiveRecord::RecordNotUnique
        raise unless key && (existing = current_api_key.outbound_messages.find_by(idempotency_key: key))
        render_record(existing, replay: true)
      end

      private

      def render_record(record, replay: false)
        result = { id: record.id, status: record.status, idempotency_key: record.idempotency_key }
        result[:idempotent] = true if replay
        render json: result, status: replay ? :ok : :accepted
      end
    end
  end
end
