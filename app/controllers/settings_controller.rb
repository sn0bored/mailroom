class SettingsController < ApplicationController
  def show
  end

  def update
    attributes = params.require(:settings).permit(:default_forward_to, :forward_sender)
    Setting.transaction do
      Setting.set("default_forward_to", attributes[:default_forward_to]) if attributes.key?(:default_forward_to)
      if ENV["MAILROOM_FORWARD_SENDER"].blank? && attributes.key?(:forward_sender)
        Setting.set("forward_sender", attributes[:forward_sender])
      end
    end
    redirect_to settings_path, notice: "Settings saved."
  end
end
