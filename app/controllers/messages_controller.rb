class MessagesController < ApplicationController
  def index
    scope = params[:archived] == "1" ? Message.archived : Message.inbox
    scope = scope.joins(:domain).where(domains: { name: params[:domain] }) if params[:domain].present?
    scope = scope.unrouted if params[:unrouted] == "1"
    scope = scope.unread if params[:unread] == "1"
    scope = scope.search(params[:q]) if params[:q].present?
    @page = [params[:page].to_i, 1].max
    rows = scope.includes(:domain).newest_first.offset((@page - 1) * 50).limit(51).to_a
    @has_next = rows.length > 50
    @messages = rows.first(50)
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
