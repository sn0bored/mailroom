require "test_helper"

class Mcp::Tools::ListDomainsTest < ActiveSupport::TestCase
  test "shows a domain's catch-all mailbox only when it has one" do
    Domain.create!(name: "example.org", catch_all_mailbox: "info@example.org", catch_all_mx_host: "mx1.example.net")
    Domain.create!(name: "example.net")
    key, _token = create_api_key(scopes: %w[mail:read])

    result = Mcp::Tools::ListDomains.call({}, key)
    domains = result[:structuredContent][:domains].index_by { |d| d[:name] }
    assert_equal "info@example.org", domains["example.org"][:catch_all_mailbox]
    assert_equal "mx1.example.net", domains["example.org"][:catch_all_mx_host]
    assert_nil domains["example.net"][:catch_all_mailbox]

    lines = result[:content].first[:text].lines.map(&:chomp)
    assert_equal "example.net | waiting for mail | unread=0 total=0 | send=off", lines[0]
    assert_equal "example.org | waiting for mail | unread=0 total=0 | send=off | catch-all mailbox=info@example.org", lines[1]
  end
end
