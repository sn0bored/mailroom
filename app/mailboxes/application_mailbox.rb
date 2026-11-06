class ApplicationMailbox < ActionMailbox::Base
  # Every message goes through one intake; routing to a domain happens inside it.
  routing all: :intake
end
