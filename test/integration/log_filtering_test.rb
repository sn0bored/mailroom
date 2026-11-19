require "test_helper"

class LogFilteringTest < ActionDispatch::IntegrationTest
  def filter(params) = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)

  test "a Postmark inbound payload keeps no sender, recipient, subject or body in the log" do
    logged = filter(JSON.parse(file_fixture("postmark_inbound.json").read)).to_json
    [ "alice@sender.example.net", "Alice Example", "hello@example.org", "Catch-all forward sample",
      "forwarded by the registrar", "X-Spam-Score" ].each do |secret|
      assert_not_includes logged, secret
    end
  end

  test "the send API's mail fields are filtered from the log" do
    logged = filter({ "from" => "sender@example.org", "to" => "recipient@example.net", "cc" => "c@example.net",
      "subject" => "Quarterly numbers", "text" => "the body", "html" => "<p>the body</p>", "reply_to" => "r@example.net" }).to_json
    [ "sender@example.org", "recipient@example.net", "c@example.net", "Quarterly numbers", "the body", "r@example.net" ].each do |secret|
      assert_not_includes logged, secret
    end
  end

  test "an authenticated Postmark POST logs no mail content" do
    Domain.create!(name: "example.org")
    log = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    ActionController::Base.logger = Rails.logger
    post Mailroom::POSTMARK_INGRESS_PATH, params: JSON.parse(file_fixture("postmark_inbound.json").read), as: :json,
         headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("actionmailbox", "test-ingress-password") },
         env: Listeners.public
    assert_response :no_content
    assert_includes log.string, "Parameters:"
    [ "alice@sender.example.net", "Catch-all forward sample", "forwarded by the registrar" ].each do |secret|
      assert_not_includes log.string, secret
    end
  ensure
    Rails.logger = original
    ActionController::Base.logger = original
  end
end
