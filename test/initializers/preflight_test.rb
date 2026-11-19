require "test_helper"

class PreflightTest < ActiveSupport::TestCase
  READY = {
    "SECRET_KEY_BASE" => "x", "RAILS_INBOUND_EMAIL_PASSWORD" => "p" * 32,
    "MAILROOM_PORT" => "3100", "MAILROOM_PUBLIC_PORT" => "3101"
  }.freeze

  def problems(overrides = {})
    Mailroom::Preflight.problems(READY.merge(overrides).compact)
  end

  test "a complete production environment boots" do
    assert_empty problems
    assert_empty problems("MAILROOM_PORT" => nil), "MAILROOM_PORT defaults to 3100"
    assert_empty problems("MAILROOM_TRUST_LOCAL" => "")
  end

  test "missing secrets are refused" do
    assert_equal [ "SECRET_KEY_BASE not set", "RAILS_INBOUND_EMAIL_PASSWORD not set" ],
      problems("SECRET_KEY_BASE" => nil, "RAILS_INBOUND_EMAIL_PASSWORD" => "")
  end

  test "a short ingress password is refused" do
    assert_equal [ "RAILS_INBOUND_EMAIL_PASSWORD is shorter than 32 characters" ],
      problems("RAILS_INBOUND_EMAIL_PASSWORD" => "p" * 31)
  end

  test "the public listener must be set and separate" do
    assert_includes problems("MAILROOM_PUBLIC_PORT" => nil), "MAILROOM_PUBLIC_PORT is not set"
    assert_includes problems("MAILROOM_PUBLIC_PORT" => " "), "MAILROOM_PUBLIC_PORT is not set"
    assert_includes problems("MAILROOM_PUBLIC_PORT" => "3100"), "MAILROOM_PUBLIC_PORT must differ from MAILROOM_PORT"
    assert_includes problems("MAILROOM_PORT" => nil, "MAILROOM_PUBLIC_PORT" => "3100"), "MAILROOM_PUBLIC_PORT must differ from MAILROOM_PORT"
    assert_includes problems("MAILROOM_PUBLIC_PORT" => "public"), "MAILROOM_PUBLIC_PORT is not a valid port"
    assert_includes problems("MAILROOM_PUBLIC_PORT" => "70000"), "MAILROOM_PUBLIC_PORT is not a valid port"
    assert_includes problems("MAILROOM_PORT" => "abc"), "MAILROOM_PORT is not a valid port"
  end

  test "MAILROOM_TRUST_LOCAL is refused in production" do
    assert_includes problems("MAILROOM_TRUST_LOCAL" => "1"), "MAILROOM_TRUST_LOCAL is for development only; remove it"
  end
end
