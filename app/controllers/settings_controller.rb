class SettingsController < ApplicationController
  def show
  end

  def update
    attributes = params.require(:settings).permit(:default_forward_to, :forward_sender, :inbound_spam_threshold)
    Setting.transaction do
      Setting.set("default_forward_to", attributes[:default_forward_to]) if attributes.key?(:default_forward_to)
      Setting.set("inbound_spam_threshold", attributes[:inbound_spam_threshold]) if attributes.key?(:inbound_spam_threshold)
      if ENV["MAILROOM_FORWARD_SENDER"].blank? && attributes.key?(:forward_sender)
        Setting.set("forward_sender", attributes[:forward_sender])
      end
    end
    redirect_to settings_path, notice: "Settings saved."
  rescue ActiveRecord::RecordInvalid => error
    flash.now[:alert] = error.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_entity
  end
end
