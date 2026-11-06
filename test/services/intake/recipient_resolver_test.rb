require "test_helper"

class Intake::RecipientResolverTest < ActiveSupport::TestCase
  test "forwarded mail routes by the registrar's X-Original-To, ignoring the provider hash the ingress prepends" do
    raw = "X-Original-To: abc123hash@inbound.postmarkapp.com\n" + forwarded_source
    result = Intake::RecipientResolver.call(Mail.new(raw), owned_names: %w[example.org])
    assert_equal "hello@example.org", result.primary
    assert_equal "hdr:X-Original-To", result.routed_via
    assert_equal [ "hello@example.org" ], result.matches
    assert_includes result.trace, { "header" => "X-Original-To", "address" => "abc123hash@inbound.postmarkapp.com" }
    assert_includes result.trace, { "header" => "Received", "address" => "hello@example.org" }
  end

  test "mx mode routes by the X-Original-To the ingress writes" do
    raw = "X-Original-To: support@mail.example.org\n" + mx_source
    result = Intake::RecipientResolver.call(Mail.new(raw), owned_names: %w[mail.example.org])
    assert_equal "support@mail.example.org", result.primary
    assert_equal "hdr:X-Original-To", result.routed_via
  end

  test "falls back to To/Cc when no envelope header matches" do
    mail = Mail.new("From: a@sender.example.net\nTo: Someone <team@example.org>\nCc: other@example.net\nSubject: x\n\nbody")
    result = Intake::RecipientResolver.call(mail, owned_names: %w[example.org])
    assert_equal "team@example.org", result.primary
    assert_equal "to:To", result.routed_via
  end

  test "unrouted when nothing matches an owned domain" do
    result = Intake::RecipientResolver.call(Mail.new(forwarded_source), owned_names: %w[other.example])
    assert result.unrouted?
    assert_equal "unrouted", result.routed_via
    assert_equal [], result.matches
    assert result.trace.any?
  end

  test "keeps plus tags and lowercases" do
    mail = Mail.new("Delivered-To: Hello+Tag@Example.ORG\nTo: x@example.org\nSubject: x\n\nbody")
    result = Intake::RecipientResolver.call(mail, owned_names: %w[example.org])
    assert_equal "hello+tag@example.org", result.primary
    assert_equal %w[hello+tag@example.org x@example.org], result.matches
  end
end
