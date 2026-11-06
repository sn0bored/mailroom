module MailroomUiHelper
  def raw_headers(message)
    message.raw_source.split(/\r?\n\r?\n/, 2).first
  rescue StandardError
    "raw source unavailable"
  end

  def display_time(value)
    value ? value.strftime("%Y-%m-%d %H:%M %Z") : "Not yet"
  end

  def relative_time(value)
    return "Not yet" unless value
    seconds = [ Time.current - value, 0 ].max.to_i
    return "Just now" if seconds < 60
    return "#{seconds / 60}m ago" if seconds < 3600
    return "#{seconds / 3600}h ago" if seconds < 86_400
    "#{seconds / 86_400}d ago"
  end

  def sender_initials(message)
    words = (message.from_name.presence || message.from_address.to_s.split("@").first).to_s.scan(/[[:alnum:]]+/)
    words.size > 1 ? words.first(2).map { |word| word.first }.join.upcase : words.first.to_s.first(2).upcase.presence || "?"
  end

  def sender_palette(message)
    message.from_address.to_s.strip.downcase.bytes.reduce(0) { |hash, byte| (hash * 31 + byte) % 5 }
  end

  def owner_navigation
    [ [ "Inbox", messages_path, "messages" ], [ "Drafts", drafts_path, "drafts" ],
      [ "Domains", domains_path, "domains" ], [ "API keys", api_keys_path, "api_keys" ],
      [ "Blocked senders", blocked_senders_path, "blocked_senders" ],
      [ "Audit", audit_events_path, "audit_events" ], [ "Settings", settings_path, "settings" ] ]
  end

  def sidebar_domains
    @sidebar_domains ||= Domain.order(:name).to_a
  end

  def sidebar_unread_counts
    @sidebar_unread_counts ||= @unread_counts || MessageQuery.new.resolve.except(:limit, :order).unread.group(:domain_id).count
  end

  def domain_inbox_path(domain)
    filters = controller_name == "messages" && action_name == "index" ? request.query_parameters.except("page", "unrouted") : {}
    messages_path(params: filters.merge("domain" => domain.name))
  end

  def owner_page_title
    return content_for(:title) if content_for?(:title)
    return @message.subject.presence || "Message" if controller_name == "messages" && @message
    return @domain.name if controller_name == "domains" && @domain&.persisted?
    return @draft.subject.presence || "Draft" if controller_name == "drafts" && @draft&.persisted?
    return "API key created" if controller_name == "api_keys" && action_name == "create" && @plaintext
    return "Add domain" if controller_name == "domains" && @domain&.new_record?
    return "New draft" if controller_name == "drafts" && @draft&.new_record?
    return "New API key" if controller_name == "api_keys" && @api_key&.new_record?
    return "Sign in" if controller_name == "sessions"
    return action_name == "edit" ? "Update password" : "Reset password" if controller_name == "passwords"
    owner_navigation.find { |_, _, section| section == controller_name }&.first || "Inbox"
  end

  def mailroom_icon
    tag.svg(viewBox: "0 0 32 32", fill: "none", aria: { hidden: true }, class: "brand-icon") do
      safe_join([ tag.rect(x: 0, y: 0, width: 32, height: 32, rx: 9, fill: "currentColor"),
        tag.rect(x: 7, y: 10, width: 18, height: 13, rx: 2, stroke: "white", "stroke-width": 1.5),
        tag.path(d: "m8 11 8 6 8-6", stroke: "white", "stroke-width": 1.5) ])
    end
  end

  def mailroom_favicon
    svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="9" fill="#0f7f8c"/><g fill="none" stroke="white" stroke-width="1.5"><rect x="7" y="10" width="18" height="13" rx="2"/><path d="m8 11 8 6 8-6"/></g></svg>'
    "data:image/svg+xml,#{ERB::Util.url_encode(svg)}"
  end
end
