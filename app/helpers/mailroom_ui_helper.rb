module MailroomUiHelper
  def raw_headers(message)
    message.raw_source.split(/\r?\n\r?\n/, 2).first
  rescue StandardError
    "raw source unavailable"
  end

  def display_time(value)
    value ? value.strftime("%Y-%m-%d %H:%M %Z") : "Not yet"
  end
end
