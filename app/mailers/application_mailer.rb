class ApplicationMailer < ActionMailer::Base
  default from: "from@example.com"
  layout "mailer"
  after_action :assign_message_id

  private

  # The Mail gem's default Message-ID ends in this machine's hostname, which every recipient would see.
  # Every message Mailroom sends uses <uuid@From domain> instead; a mailer that needs the id before
  # mail() (the loop marker is computed from it) calls this itself and sets the header.
  def new_message_id(from_address)
    domain = Mail::Address.new(from_address.to_s).domain.presence
    "<#{SecureRandom.uuid}@#{domain || 'mailroom.invalid'}>"
  rescue Mail::Field::ParseError
    "<#{SecureRandom.uuid}@mailroom.invalid>"
  end

  def assign_message_id
    message.message_id = new_message_id(Array(message.from).first) if message.message_id.blank?
  end
end
