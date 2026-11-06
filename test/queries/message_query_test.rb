require "test_helper"

class MessageQueryTest < ActiveSupport::TestCase
  setup do
    Domain.create!(name: "example.org")
    @routed = receive_source("X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source)
    @unrouted = receive_source(mx_source)
  end

  test "filters by domain, unrouted, unread, search and limit" do
    assert_equal [ @routed ], MessageQuery.new({ domain: "example.org" }).resolve.to_a
    assert_equal [ @unrouted ], MessageQuery.new({ unrouted: true }).resolve.to_a
    assert_equal 2, MessageQuery.new({ unread: true }).resolve.count
    assert_equal [ @routed ], MessageQuery.new({ q: "catch-all" }).resolve.to_a
    assert_equal 1, MessageQuery.new({ limit: 1 }).resolve.count
    assert_equal 100, MessageQuery.new({ limit: 5000 }).limit
  end

  test "archived switches to the archive" do
    @routed.archive!
    assert_equal [ @unrouted ], MessageQuery.new({}).resolve.to_a
    assert_equal [ @routed ], MessageQuery.new({ archived: true }).resolve.to_a
  end
end
