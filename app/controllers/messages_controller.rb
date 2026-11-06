class MessagesController < ApplicationController
  def index
    filters = params.permit(:archived, :domain, :unrouted, :unread, :q, :blocked).to_h
    scope = MessageQuery.new(filters).resolve.except(:limit)
    @domains = Domain.order(:name)
    @unread_counts = MessageQuery.new(filters.except("domain", "unrouted", "unread", "q"))
      .resolve.except(:limit, :order).unread.group(:domain_id).count
    @group_by_domain = params[:group] != "none"
    @page = [ params[:page].to_i, 1 ].max
    rows = scope.includes(:domain).newest_first.offset((@page - 1) * 50).limit(51).to_a
    @has_next = rows.length > 50
    @messages = rows.first(50)
    @message_groups = @messages.group_by(&:domain).sort_by { |domain, _| [ domain ? 0 : 1, domain&.name.to_s ] }
  end

  def show
    @message = Message.find(params[:id])
    @message.mark_read!
  end

  def update
    message = Message.find(params[:id])
    message.mark_read! if params[:read] == "1"
    message.mark_unread! if params[:read] == "0"
    message.archive! if params[:archived] == "1"
    message.unarchive! if params[:archived] == "0"
    redirect_back fallback_location: message_path(message)
  end
end
