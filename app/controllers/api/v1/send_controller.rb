module Api
  module V1
    class SendController < BaseController
      before_action { require_scope!("mail:send") }

      # Nothing is stored until the message is valid and Outbound::Send accepts it, so a refused
      # request leaves no row behind and a retry with the same idempotency key is judged again.
      # Requests are stored as queued; replay is accepted once enqueueing has succeeded. The record
      # is built as queued because an API send never exists as a draft.
      def create
        key = params[:idempotency_key]
        if key.is_a?(ActionController::Parameters) || key.is_a?(Array)
          return render json: { error: "invalid", details: [ "Idempotency key must be a string" ] }, status: :unprocessable_entity
        end
        key = key.to_s.presence
        existing = own_sends.find_by(idempotency_key: key) if key
        return render_record(existing, replay: true) if existing

        record = own_sends.new(status: "queued", idempotency_key: key,
          from_address: params[:from], to_addresses: Array(params[:to]),
          cc_addresses: Array(params[:cc]), bcc_addresses: Array(params[:bcc]),
          subject: params[:subject], text_body: params[:text], html_body: params[:html],
          reply_to: params[:reply_to], in_reply_to: params[:in_reply_to])
        record.validate!
        Outbound::Send.call(record, actor: current_api_key)
        Audit.record("api.send", actor: current_api_key, target: record, ip: request.remote_ip)
        render_record(record)
      rescue ActiveRecord::RecordNotUnique
        # A concurrent request stored the same key first; it may still be enqueueing.
        raise unless key && (existing = own_sends.find_by(idempotency_key: key))
        render_record(existing, replay: true)
      end

      # Status of one of this key's own sends. Another key's message is a 404, like a missing one.
      def show
        record = own_sends.find_by(id: params[:id])
        return render json: { error: "not_found" }, status: :not_found unless record

        render json: message_json(record)
      end

      private

      def own_sends = current_api_key.outbound_messages.where(kind: "api")

      def render_record(record, replay: false)
        if replay && record.status == "queued" && record.delivery_job_id.nil?
          return render json: { error: "in_progress" }, status: :conflict
        end

        result = message_json(record)
        result[:idempotent] = true if replay
        render json: result, status: replay ? :ok : :accepted
      end

      # Status and delivery metadata only: never bodies, subjects or addresses.
      def message_json(record)
        { id: record.id, status: record.status, idempotency_key: record.idempotency_key,
          error: record.error, created_at: record.created_at&.utc&.iso8601,
          sent_at: record.sent_at&.utc&.iso8601, provider_message_id: record.postmark_message_id }
      end
    end
  end
end
