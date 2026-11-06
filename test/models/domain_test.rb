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
end
