class AttachmentsController < ApplicationController
  def show
    message = Message.find(params[:message_id])
    attachment = message.attachments.find(params[:id])
    send_data attachment.download, filename: attachment.filename.to_s,
      type: attachment.content_type, disposition: "attachment"
  end
end
