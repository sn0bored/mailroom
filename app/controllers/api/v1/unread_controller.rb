module Api
  module V1
    class UnreadController < BaseController
      def show
        counts = unread_counts_by_domain_id
        domains = Domain.active.order(:name).map do |domain|
          { domain: domain.name, unread: counts[domain.id].to_i }
        end
        render json: { total_unread: domains.sum { |d| d[:unread] }, domains: domains,
          checked_at: Time.current.utc.iso8601 }
      end

      private

      # Same aggregation the owner UI runs for its unread badges (see MessagesController#index).
      def unread_counts_by_domain_id
        MessageQuery.new({}).resolve.except(:limit, :order).unread.group(:domain_id).count
      end
    end
  end
end
