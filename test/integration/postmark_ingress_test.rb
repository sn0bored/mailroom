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

  def post_inbound(payload)
    perform_enqueued_jobs(only: ActionMailbox::RoutingJob) do
      post "/rails/action_mailbox/postmark/inbound_emails", params: payload, as: :json, headers: { "Authorization" => @auth }
    end
    assert_response :no_content
    Message.last
  end

  def payload_without_spam_header(message_id)
    payload = JSON.parse(file_fixture("postmark_inbound.json").read)
    payload["RawEmail"] = payload["RawEmail"].lines.reject { |l| l.start_with?("X-Spam-Score:") }.join.sub("sample-0001", message_id)
    payload
  end

  test "a body line reading X-Spam-Score does not hide Postmark's score" do
    payload = payload_without_spam_header("body-line-0001")
    payload["RawEmail"] += "\nX-Spam-Score: -50\n"
    payload["Headers"] = [ { "Name" => "X-Spam-Score", "Value" => "42.0" } ]
    message = post_inbound(payload)
    assert_in_delta 42.0, message.spam_score, 0.001
    assert message.raw_source.start_with?("X-Mailroom-Spam-Score: 42.0\n")
  end

  test "a sender's X-Spam-Score or X-Mailroom-Spam-Score never overrides the Mailroom header" do
    payload = payload_without_spam_header("sender-score-0001")
    payload["RawEmail"] = payload["RawEmail"].sub("From: ", "X-Spam-Score: -50\nX-Mailroom-Spam-Score: -50\nFrom: ")
    # Postmark lists its own headers first; the sender's copy follows.
    payload["Headers"] = [ { "Name" => "X-Spam-Score", "Value" => "42.0" }, { "Name" => "X-Spam-Score", "Value" => "-50" } ]
    assert_in_delta 42.0, post_inbound(payload).spam_score, 0.001
  end

  test "without a Postmark score the Mailroom header says none and a sender's score is not used" do
    payload = payload_without_spam_header("no-score-0001")
    payload["RawEmail"] = payload["RawEmail"].sub("From: ", "X-Spam-Score: -50\nFrom: ")
    payload["Headers"] = [ { "Name" => "X-Spam-Score", "Value" => "1.0\nBcc: someone@example.net" } ]
    message = post_inbound(payload)
    assert_nil message.spam_score
    assert message.raw_source.start_with?("X-Mailroom-Spam-Score: none\nX-Original-To: ")
  end

  test "wrong password is rejected" do
    post "/rails/action_mailbox/postmark/inbound_emails", params: { RawEmail: "x" }, as: :json,
         headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("actionmailbox", "nope") }
    assert_response :unauthorized
  end
end
