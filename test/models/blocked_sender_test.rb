require "test_helper"

class BlockedSenderTest < ActiveSupport::TestCase
  test "full addresses match exactly ignoring case and surrounding whitespace" do
    sender = BlockedSender.create!(pattern: " Spam@Example.NET ", note: "Unwanted mail")
    assert_equal "spam@example.net", sender.pattern
    assert BlockedSender.blocks?(" SPAM@EXAMPLE.NET ")
    assert_not BlockedSender.blocks?("other@example.net")
    assert_not BlockedSender.blocks?("spam@sub.example.net")
    assert_not BlockedSender.new(pattern: "SPAM@example.net").valid?
  end

  test "bare domains match any address at exactly that domain" do
    BlockedSender.create!(pattern: "EXAMPLE.NET")
    assert BlockedSender.blocks?("one@example.net")
    assert BlockedSender.blocks?("TWO@EXAMPLE.NET")
    assert_not BlockedSender.blocks?("one@sub.example.net")
    assert_not BlockedSender.blocks?("one@example.org")
    assert_not BlockedSender.blocks?("example.net")
    assert_not BlockedSender.blocks?(nil)
  end

  test "rejects empty and malformed patterns" do
    [ nil, "", " ", "@example.net", "one@@example.net", "https://example.net", "a b@example.net", "example.net/path" ].each do |pattern|
      assert_not BlockedSender.new(pattern: pattern).valid?, pattern.inspect
    end
  end

  test "removing a block permits future mail" do
    sender = BlockedSender.create!(pattern: "example.net")
    sender.destroy!
    assert_not BlockedSender.blocks?("sender@example.net")
  end
end
