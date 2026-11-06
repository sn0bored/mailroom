class BlockedSendersController < ApplicationController
  def index
    @blocked_sender = BlockedSender.new
    @blocked_senders = BlockedSender.order(:pattern)
  end

  def create
    @blocked_sender = BlockedSender.new(params.require(:blocked_sender).permit(:pattern, :note))
    if @blocked_sender.save
      redirect_to blocked_senders_path, notice: "Sender blocked. Future messages will be stored without forwarding."
    else
      @blocked_senders = BlockedSender.order(:pattern)
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    BlockedSender.find(params[:id]).destroy!
    redirect_to blocked_senders_path, notice: "Sender removed from the block list."
  end
end
