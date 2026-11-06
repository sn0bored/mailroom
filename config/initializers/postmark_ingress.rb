Rails.application.config.to_prepare do
  ActionMailbox::Ingresses::Postmark::InboundEmailsController.prepend(PostmarkIngressSpamScore)
end
