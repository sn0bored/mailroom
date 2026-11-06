require "test_helper"
require_relative "../support/outbound_stubs"

class OwnerUiTest < ActionDispatch::IntegrationTest
  using OutboundStubs

  setup do
    Rack::Attack.reset!
    host! "example.org:8443"
    @user = User.create!(email_address: "owner@example.org", password: "test-password")
    @domain = Domain.create!(name: "example.org")
    sign_in_as(@user)
  end

  def sign_in_as(user)
    post session_path, params: { email_address: user.email_address, password: "test-password" }
    assert_redirected_to root_path
  end

  def create_message(**attributes)
    source = File.read(Rails.root.join("test/fixtures/files/forwarded_sample.eml"))
    source = source.sub("sample-0001@", "#{SecureRandom.hex(8)}@")
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    Message.create!({ inbound_email: inbound, domain: @domain, received_at: Time.current,
      from_address: "sender@example.net", to_address: "inbox@example.org", subject: "A sample message",
      body_text: "Hello\n<script>alert('mail')</script>", snippet: "A short preview", routed_via: "original_to",
      matched_addresses: ["inbox@example.org"], rfc822_message_id: "<source@example.net>" }.merge(attributes))
  end

  def draft_attributes
    { from_address: "owner@example.org", to: "first@example.net, second@example.net", subject: "A draft", text_body: "Plain text" }
  end

  def create_draft(**attributes)
    OutboundMessage.create!({ kind: "reply", status: "draft", user: @user,
      from_address: "owner@example.org", to_addresses: ["recipient@example.net"], subject: "Draft", text_body: "Text" }.merge(attributes))
  end

  test "all owner pages require a session" do
    message = create_message
    draft = create_draft
    key, = create_api_key
    delete session_path
    [root_path, messages_path, message_path(message), domains_path, new_domain_path, domain_path(@domain),
     drafts_path, new_draft_path, draft_path(draft), api_keys_path, new_api_key_path,
     audit_events_path, settings_path, message_attachment_path(message, 1)].each do |path|
      get path
      assert_redirected_to new_session_path
    end
    [[:post, domains_path], [:patch, domain_path(@domain)], [:post, probe_domain_path(@domain)],
     [:patch, message_path(message)], [:post, drafts_path], [:patch, draft_path(draft)],
     [:post, deliver_draft_path(draft)], [:post, api_keys_path], [:delete, api_key_path(key)],
     [:patch, settings_path]].each do |method, path|
      public_send(method, path)
      assert_redirected_to new_session_path
    end
  end

  test "login and sign out retain generator behavior" do
    delete session_path
    get new_session_path
    assert_select "label[for=email_address]", "Email address"
    assert_select "a[href=?]", new_password_path
    post session_path, params: { email_address: @user.email_address, password: "incorrect" }
    assert_redirected_to new_session_path
    assert flash[:alert].present?
  end

  test "inbox lists fixture backed mail with routing and spam status" do
    message = create_message(spam_score: 5.2)
    get messages_path
    assert_response :ok
    assert_select ".message-row.unread", 1
    assert_select "a[href=?]", message_path(message), text: message.subject
    assert_includes response.body, "A short preview"
    assert_includes response.body, "original_to"
    assert_includes response.body, "Spam score: 5.2"
    assert_includes response.body, "example.org"
  end

  test "inbox filters combine domain unread archived unrouted and search" do
    wanted = create_message(subject: "Find needle", archived_at: Time.current)
    create_message(subject: "Read needle", read_at: Time.current, archived_at: Time.current)
    create_message(subject: "Different", archived_at: Time.current)
    unrouted = create_message(domain: nil, subject: "Lost mail")
    get messages_path, params: { domain: "example.org", unread: "1", archived: "1", q: "needle" }
    assert_select ".message-row", 1
    assert_select "a[href=?]", message_path(wanted)
    get messages_path, params: { unrouted: "1" }
    assert_select ".message-row", 1
    assert_select "a[href=?]", message_path(unrouted)
    get messages_path
    assert_select ".message-row", 1
    get messages_path, params: { domain: "example.net" }
    assert_select ".message-row", 0
  end

  test "inbox pagination preserves filters" do
    create_message
    50.times do |index|
      create_message(subject: "Page #{index}")
    end
    get messages_path, params: { domain: "example.org", unread: "1" }
    assert_select ".message-row", 50
    assert_select "a", text: "Next"
    get messages_path, params: { domain: "example.org", unread: "1", page: 2 }
    assert_select ".message-row", 1
    assert_select "a", text: "Previous"
    assert_select "a", text: "Next", count: 0
  end

  test "show marks read and escapes mail and raw headers" do
    message = create_message
    get message_path(message)
    assert_response :ok
    assert message.reload.read?
    assert_select "pre.body", text: message.body_text
    assert_select "pre script", 0
    assert_select "summary", "Raw headers"
    assert_select "details pre", text: /Return-Path:/
    assert_select "details pre", text: /This message was sent/, count: 0
    assert_select "a[href=?]", new_draft_path(message_id: message.id)
  end

  test "unavailable raw source has a readable fallback" do
    message = create_message
    message.stub(:raw_source, -> { raise IOError }) do
      Message.stub(:find, message) do
        get message_path(message)
        assert_response :ok
        assert_includes response.body, "raw source unavailable"
      end
    end
  end

  test "message updates use read and archive toggles" do
    message = create_message
    patch message_path(message), params: { read: "1", archived: "1" }
    assert_redirected_to message_path(message)
    assert message.reload.read?
    assert message.archived?
    patch message_path(message), params: { read: "0", archived: "0" }
    assert_not message.reload.read?
    assert_not message.archived?
  end

  test "attachment downloads are scoped to their message" do
    message = create_message
    message.attachments.attach(io: StringIO.new("file content"), filename: "sample.txt", content_type: "text/plain")
    attachment = message.attachments.first
    get message_attachment_path(message, attachment)
    assert_response :ok
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_includes response.headers["Content-Disposition"], "sample.txt"
    assert_equal "file content", response.body
    other = create_message
    get message_attachment_path(other, attachment)
    assert_response :not_found
  end

  test "domain pages create update and show setup and recent mail" do
    get domains_path
    assert_response :ok
    assert_includes response.body, "waiting for mail"
    get new_domain_path
    assert_response :ok
    post domains_path, params: { domain: { name: "example.net", forward_copy_to: "copy@example.org",
      send_enabled: "1", forward_copy_max_spam: 4, notes: "Notes" } }
    domain = Domain.find_by!(name: "example.net")
    assert_redirected_to domain_path(domain)
    assert domain.send_enabled?
    patch domain_path(domain), params: { domain: { send_enabled: "0", notes: "Updated" } }
    assert_equal "Updated", domain.reload.notes
    assert_not domain.send_enabled?
    create_message
    Mailroom.stub(:inbound_address, nil) do
      get domain_path(@domain)
      assert_response :ok
      assert_includes response.body, "mailroom:postmark:configure"
      assert_includes response.body, "A sample message"
    end
    Mailroom.stub(:inbound_address, "inbound@example.net") do
      get domain_path(@domain)
      assert_includes response.body, "inbound@example.net"
      assert_select ".setup-line", text: /Add a catch-all forwarder/
    end
    post domains_path, params: { domain: { name: "invalid" } }
    assert_response :unprocessable_entity
    patch domain_path(@domain), params: { domain: { name: "invalid" } }
    assert_response :unprocessable_entity
  end

  test "probe shows success and both service error types" do
    Outbound::Probe.stub(:call, ->(domain, actor:) { assert_equal @domain, domain; assert_equal @user, actor }) do
      post probe_domain_path(@domain)
      assert_redirected_to domain_path(@domain)
      assert_equal "Probe queued.", flash[:notice]
    end
    [NotImplementedError, Outbound::Send::NotAllowed].each do |error|
      Outbound::Probe.stub(:call, ->(*) { raise error, "Probe unavailable" }) do
        post probe_domain_path(@domain)
        assert_redirected_to domain_path(@domain)
        assert_equal "Probe unavailable", flash[:alert]
      end
    end
  end

  test "reply prefills and persists threading and quoted plain text" do
    message = create_message(reply_to: "reply@example.net", references_header: "<earlier@example.net>")
    get new_draft_path, params: { message_id: message.id }
    assert_response :ok
    assert_select "input[name='draft[from_address]'][value='inbox@example.org']"
    assert_select "input[name='draft[to]'][value='reply@example.net']"
    assert_select "input[name='draft[subject]'][value='Re: A sample message']"
    assert_select "textarea", text: /> Hello\n> <script>/
    post drafts_path, params: { message_id: message.id, draft: draft_attributes }
    draft = OutboundMessage.last
    assert_redirected_to draft_path(draft)
    assert_equal "reply", draft.kind
    assert_equal @user, draft.user
    assert_equal message, draft.source_message
    assert_equal message.rfc822_message_id, draft.in_reply_to
    assert_equal "<earlier@example.net> <source@example.net>", draft.references_header
    assert_equal %w[first@example.net second@example.net], draft.to_addresses
    message.update!(subject: "RE: Already a reply", reply_to: nil)
    get new_draft_path, params: { message_id: message.id }
    assert_select "input[name='draft[subject]'][value='RE: Already a reply']"
    assert_select "input[name='draft[to]'][value='sender@example.net']"
  end

  test "plain drafts can be created edited and listed" do
    get new_draft_path
    assert_response :ok
    post drafts_path, params: { draft: draft_attributes }
    draft = OutboundMessage.last
    assert_equal "api", draft.kind
    get drafts_path
    assert_response :ok
    assert_select "a[href=?]", draft_path(draft)
    get draft_path(draft)
    assert_response :ok
    assert_select "summary", "Edit"
    patch draft_path(draft), params: { draft: draft_attributes.merge(subject: "Changed", status: "sent") }
    assert_equal "Changed", draft.reload.subject
    assert_equal "draft", draft.status
    post drafts_path, params: { draft: draft_attributes.merge(from_address: "") }
    assert_response :unprocessable_entity
    patch draft_path(draft), params: { draft: draft_attributes.merge(to: "") }
    assert_response :unprocessable_entity
  end

  test "deliver passes actor and flashes service errors" do
    draft = create_draft
    Outbound::Send.stub(:call, ->(record, actor:) { assert_equal draft, record; assert_equal @user, actor }) do
      post deliver_draft_path(draft)
      assert_redirected_to draft_path(draft)
      assert_equal "Message queued for sending.", flash[:notice]
    end
    [NotImplementedError, Outbound::Send::NotAllowed].each do |error|
      Outbound::Send.stub(:call, ->(*) { raise error, "Sending unavailable" }) do
        post deliver_draft_path(draft)
        assert_redirected_to draft_path(draft)
        assert_equal "Sending unavailable", flash[:alert]
      end
    end
  end

  test "sent and queued drafts cannot be edited or resent" do
    %w[sent queued].each do |status|
      draft = create_draft(status: status, sent_at: status == "sent" ? Time.current : nil)
      get draft_path(draft)
      assert_response :ok
      assert_select "form[action=?]", deliver_draft_path(draft), count: 0
      patch draft_path(draft), params: { draft: draft_attributes }
      assert_equal status, draft.reload.status
      assert_equal "Draft", draft.subject
      post deliver_draft_path(draft)
      assert_equal "Only drafts can be sent.", flash[:alert]
    end
  end

  test "api key plaintext is shown once then only its label and revoke preserves record" do
    get new_api_key_path
    assert_response :ok
    assert_select "input[type=checkbox]", ApiKey::SCOPES.length
    post api_keys_path, params: { api_key: { name: "Reader", scopes: ["mail:read"], allowed_from_domains: "example.org, example.net" } }
    assert_response :created
    token = css_select("pre.token").first.text.strip
    key = ApiKey.authenticate(token)
    assert key
    assert_equal %w[example.org example.net], key.allowed_from_domains
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_includes response.body, "It will not be shown again."
    get api_keys_path
    assert_response :ok
    assert_not_includes response.body, token
    assert_includes response.body, key.label
    assert_no_difference "ApiKey.count" do
      delete api_key_path(key)
    end
    assert key.reload.revoked_at
    assert_nil ApiKey.authenticate(token)
    post api_keys_path, params: { api_key: { name: "Invalid", scopes: ["unknown"] } }
    assert_response :unprocessable_entity
  end

  test "audit shows only latest two hundred events" do
    201.times { |index| AuditEvent.create!(action: "event.#{index}", created_at: Time.current + index.seconds) }
    get audit_events_path
    assert_response :ok
    assert_select "tbody tr", 200
    assert_select "tbody tr:first-child td", text: "event.200"
    assert_select "td", text: "event.0", count: 0
  end

  test "settings save defaults and respect environment sender override" do
    original = ENV.delete("MAILROOM_FORWARD_SENDER")
    get settings_path
    assert_response :ok
    assert_includes response.body, Mailroom::VERSION
    assert_select "input[name='settings[forward_sender]']"
    patch settings_path, params: { settings: { default_forward_to: "copy@example.org", forward_sender: "sender@example.org" } }
    assert_redirected_to settings_path
    assert_equal "copy@example.org", Setting.get("default_forward_to")
    assert_equal "sender@example.org", Setting.get("forward_sender")
    ENV["MAILROOM_FORWARD_SENDER"] = "fixed@example.net"
    get settings_path
    assert_includes response.body, "fixed@example.net"
    assert_select "input[name='settings[forward_sender]']", 0
    patch settings_path, params: { settings: { forward_sender: "ignored@example.org" } }
    assert_equal "sender@example.org", Setting.get("forward_sender")
  ensure
    original.nil? ? ENV.delete("MAILROOM_FORWARD_SENDER") : ENV["MAILROOM_FORWARD_SENDER"] = original
  end
end
