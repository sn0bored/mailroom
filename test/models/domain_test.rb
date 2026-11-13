require "test_helper"

class DomainTest < ActiveSupport::TestCase
  test "defaults preserve all forwarding and lists are independent" do
    domain = Domain.new(name: "example.org", forward_copy_to: "owner@example.net")
    assert_equal "all", domain.forward_mode
    assert_empty domain.forward_addresses
    domain.forward_addresses << "hello"
    assert_empty Domain.new.forward_addresses
    assert domain.forwarding?
    assert domain.forward_copy_for?(Message.new(to_address: "anything@example.org"))
  end

  test "listed addresses match local parts ignoring case and accept full addresses" do
    domain = Domain.create!(name: "example.org", forward_copy_to: "owner@example.net",
      forward_mode: "listed", forward_addresses: [ "HELLO", "Sales@Example.ORG" ])
    assert domain.reload.forward_copy_for?(Message.new(to_address: "Hello@example.org"))
    assert domain.forward_copy_for?(Message.new(to_address: "sales@example.org"))
    assert_not domain.forward_copy_for?(Message.new(to_address: "random@example.org"))
    assert_not domain.forward_copy_for?(Message.new(to_address: nil))
    domain.forward_addresses = nil
    assert_not domain.forward_copy_for?(Message.new(to_address: "hello@example.org"))
  end

  test "off disables a configured target and invalid modes are rejected" do
    domain = Domain.new(name: "example.org", forward_copy_to: "owner@example.net", forward_mode: "off")
    assert_not domain.forwarding?
    assert_not domain.forward_copy_for?(Message.new(to_address: "hello@example.org"))
    domain.forward_mode = "invalid"
    assert_not domain.valid?
  end

  test "a catch-all mailbox is normalised and must be on the domain itself" do
    domain = Domain.create!(name: "example.org", catch_all_mailbox: "  Info@Example.ORG ")
    assert_equal "info@example.org", domain.catch_all_mailbox
    domain.update!(catch_all_mailbox: " ")
    assert_nil domain.catch_all_mailbox

    [ "info@example.net", "info@mail.example.org", "example.org", "@example.org", "in fo@example.org", "a@b@example.org" ].each do |address|
      domain.catch_all_mailbox = address
      assert_not domain.valid?, address
      assert_includes domain.errors[:catch_all_mailbox], "must be an address on this domain, such as info@example.org"
    end
  end

  test "a catch-all mailbox can't also be where copies are forwarded" do
    domain = Domain.new(name: "example.org", forward_copy_to: "Info@example.org", catch_all_mailbox: "info@example.org")
    assert_not domain.valid?
    assert_includes domain.errors[:catch_all_mailbox], "can't also be where copies are forwarded"
  end

  test "only active domains contribute catch-all mailboxes" do
    Domain.create!(name: "example.org", catch_all_mailbox: "info@example.org")
    Domain.create!(name: "example.net", catch_all_mailbox: "hello@example.net", active: false)
    Domain.create!(name: "example.com")
    assert_equal [ "info@example.org" ], Domain.catch_all_mailboxes
  end
end
