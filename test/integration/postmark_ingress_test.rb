require "test_helper"

class PostmarkIngressTest < ActionDispatch::IntegrationTest
  setup do
    Domain.create!(name: "example.org")
    @auth = ActionController::HttpAuthentication::Basic.encode_credentials("actionmailbox", "test-ingress-password")
  end

  test "a Postmark payload with RawEmail is stored and routed" do
    payload = JSON.parse(file_fixture("postmark_inbound.json").read)
    perform_enqueued_jobs do
      post "/rails/action_mailbox/postmark/inbound_emails", params: payload, as: :json, headers: { "Authorization" => @auth }
    end
    assert_response :no_content
    message = Message.last
    assert_equal "hello@example.org", message.to_address
    assert_equal "hdr:X-Original-To", message.routed_via
  end

  test "spam score is copied from the JSON headers when the raw email lacks it" do
    payload = JSON.parse(file_fixture("postmark_inbound.json").read)
    payload["RawEmail"] = payload["RawEmail"].lines.reject { |l| l.start_with?("X-Spam-Score:") }.join
    payload["Headers"] = [ { "Name" => "X-Spam-Score", "Value" => "7.3" } ]
    perform_enqueued_jobs do
      post "/rails/action_mailbox/postmark/inbound_emails", params: payload, as: :json, headers: { "Authorization" => @auth }
    end
    assert_in_delta 7.3, Message.last.spam_score, 0.001
  end

  test "wrong password is rejected" do
    post "/rails/action_mailbox/postmark/inbound_emails", params: { RawEmail: "x" }, as: :json,
         headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("actionmailbox", "nope") }
    assert_response :unauthorized
  end
end
