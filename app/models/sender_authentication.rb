# What the receiving side learned about who sent a message, read from its stored raw source.
#
# 1. A trusted Authentication-Results decides when there is one. Mail forwarded by a registrar
#    reaches Postmark from the forwarder, which checked the real sender first and recorded the
#    verdict there. It counts only when its authserv-id is listed in MAILROOM_TRUSTED_AUTHSERV_IDS,
#    and only the topmost such header counts; copies a sender planted sit below it.
# 2. Otherwise the verdict comes from Postmark's own signals: the topmost Received-SPF and the
#    SpamAssassin rules in X-Spam-Tests (Postmark writes no Authentication-Results and no DMARC).
#    - pass: DKIM_VALID_AU (a valid signature from the From domain), or an SPF pass for an envelope
#      domain aligned with the From domain.
#    - fail: no aligned DKIM, and an SPF fail or softfail for an envelope domain aligned with the
#      From domain, so the domain's own SPF rejected the host that sent this.
#    - none: anything else. That includes forwarded mail, where Postmark's SPF result describes
#      the forwarder's envelope and says nothing about the sender.
#    SPF is reported only when the envelope domain aligns, and the DMARC policy is never looked up.
# A sender can write any of these headers too. Postmark adds its own above the ones that arrive
# with the message, so only the topmost copy of each counts.
class SenderAuthentication
  SPF_RESULTS = %w[pass fail softfail neutral none temperror permerror].freeze

  attr_reader :dmarc, :spf, :dkim, :source

  def self.unknown = new(dmarc: "none", spf: "none", dkim: "none", source: nil)

  def self.parse(raw, from_address:)
    fields = header_fields(raw)
    from_domain = from_address.to_s.split("@").last.to_s.downcase
    from_authentication_results(fields) || from_provider_signals(fields, from_domain) || unknown
  end

  def initialize(dmarc:, spf:, dkim:, source:)
    @dmarc, @spf, @dkim, @source = dmarc, spf, dkim, source
  end

  def known? = source.present?
  def failed? = dmarc == "fail"

  def summary
    return "Unavailable" unless known?
    verdict = { "pass" => "verified", "fail" => "unverified" }.fetch(dmarc, "unknown")
    "#{verdict} (DMARC #{dmarc}, SPF #{spf}, DKIM #{dkim})"
  end

  class << self
    private

    # [name, value] pairs in the order they appear, folded lines joined.
    def header_fields(raw)
      head = raw.to_s.b.split(/\r?\n\r?\n/, 2).first.to_s
      head.each_line.with_object([]) do |line, fields|
        if line.match?(/\A[ \t]/)
          fields.last[1] = "#{fields.last[1]} #{line.strip}" if fields.any?
        elsif (separator = line.index(":"))
          fields << [ line[0, separator].strip.downcase, line[(separator + 1)..].strip ]
        end
      end
    end

    def from_authentication_results(fields)
      trusted = Mailroom.trusted_authserv_ids
      return nil if trusted.empty?
      _, value = fields.find { |name, v| name == "authentication-results" && trusted.include?(authserv_id(v)) }
      return nil unless value
      results = value.split(";").drop(1).filter_map do |item|
        match = item.strip.match(/\A(dmarc|spf|dkim)\s*=\s*([a-z]+)/i)
        [ match[1].downcase, match[2].downcase ] if match
      end
      first = ->(method) { results.find { |m, _| m == method }&.last }
      dkim = results.any? { |m, r| m == "dkim" && r == "pass" } ? "pass" : first.("dkim")
      new(dmarc: limit(first.("dmarc"), %w[pass fail]), spf: limit(first.("spf"), SPF_RESULTS),
          dkim: limit(dkim, %w[pass fail]), source: "authentication-results")
    end

    def from_provider_signals(fields, from_domain)
      received_spf = fields.find { |name, _| name == "received-spf" }&.last
      spam_tests = fields.find { |name, _| name == "x-spam-tests" }&.last
      return nil if received_spf.nil? && spam_tests.nil?

      rules = spam_tests.to_s.upcase.split(/[\s,]+/)
      # A valid signature from some other domain (an ESP, a list) is neither a pass nor a failure here.
      dkim = if rules.include?("DKIM_VALID_AU") then "pass"
      elsif rules.include?("DKIM_INVALID") || (rules.include?("DKIM_SIGNED") && !rules.include?("DKIM_VALID")) then "fail"
      else "none"
      end
      spf = aligned?(spf_envelope_domain(received_spf), from_domain) ? limit(received_spf[/\A(\w+)/, 1].to_s.downcase, SPF_RESULTS) : "none"
      dmarc = if dkim == "pass" || spf == "pass" then "pass"
      elsif %w[fail softfail].include?(spf) then "fail"
      else "none"
      end
      new(dmarc: dmarc, spf: spf, dkim: dkim, source: "provider")
    end

    def authserv_id(value)
      value.split(";").first.to_s.strip.split(/\s+/).first.to_s.downcase
    end

    def spf_envelope_domain(received_spf)
      return nil if received_spf.nil?
      identity = received_spf[/identity=([\w-]+)/i, 1]
      return nil if identity && !identity.casecmp?("mailfrom")
      received_spf[/envelope-from=["<]?([^;\s">]+)/i, 1].to_s.split("@").last&.downcase
    end

    # Relaxed alignment without a public-suffix list: the same domain or one a subdomain of the other.
    def aligned?(envelope_domain, from_domain)
      return false if envelope_domain.blank? || from_domain.blank?
      envelope_domain == from_domain || envelope_domain.end_with?(".#{from_domain}") || from_domain.end_with?(".#{envelope_domain}")
    end

    def limit(value, allowed)
      allowed.include?(value) ? value : "none"
    end
  end
end
