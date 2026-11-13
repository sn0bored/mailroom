# Sender checks use only ingress-owned Postmark signals or a configured forwarder's results inside
# the trusted Received boundary. Legacy raw provider headers and sender-supplied results are ignored.
class SenderAuthentication
  SPF_RESULTS = %w[pass fail softfail neutral none temperror permerror].freeze

  attr_reader :dmarc, :spf, :dkim, :source, :from_count

  def self.unknown = new(dmarc: "none", spf: "none", dkim: "none", source: nil)

  def self.parse(raw, from_address:)
    fields = MailHeaders.fields(raw)
    count = fields.count { |name, _| name == "from" }
    return new(dmarc: "none", spf: "none", dkim: "none", source: "multiple_from", from_count: count) if count > 1
    from_domain = from_address.to_s.split("@").last.to_s.downcase
    provider = from_provider_signals(fields, from_domain)
    return unknown unless provider
    from_authentication_results(fields, from_domain) || provider
  end

  def initialize(dmarc:, spf:, dkim:, source:, from_count: 1)
    @dmarc, @spf, @dkim, @source = dmarc, spf, dkim, source
    @from_count = from_count
  end

  def known? = source.present?
  def failed? = from_count > 1 || dmarc == "fail"

  def summary(domain: nil)
    return "unverified (multiple From headers)" if from_count > 1
    return "Unavailable" unless known?
    verdict = { "pass" => "verified", "fail" => "unverified" }.fetch(dmarc, "unknown")
    "#{verdict}#{" for #{domain}" if domain.present?} (DMARC #{dmarc}, SPF #{spf}, DKIM #{dkim})"
  end

  class << self
    private

    def from_authentication_results(fields, from_domain)
      trusted = Mailroom.trusted_authserv_ids
      hosts = Mailroom.trusted_forwarder_hosts
      return nil if trusted.empty? || hosts.empty?

      # Anchor trust at the first Received, never at a sender's planted Postmark hop further down.
      hop = fields.find { |name, _| name == "received" }&.last
      from, by = received_hosts(hop)
      return nil unless host_matches?(by, [ "postmarkapp.com" ]) && host_matches?(from, hosts)

      fields.each do |name, value|
        if name == "received"
          _, receiver = received_hosts(value)
          break unless host_matches?(receiver, [ "postmarkapp.com", *hosts ])
        elsif name == "authentication-results" && trusted.include?(authserv_id(value))
          return authentication_results(value, from_domain)
        end
      end
      nil
    end

    def authentication_results(value, from_domain)
      results = (result_tokens(value) || []).drop(1).filter_map do |tokens|
        method, equals, result, *properties = tokens
        next unless equals == "=" && %w[dmarc spf dkim].include?(method.to_s.downcase)
        next unless properties.length % 3 == 0
        attributes = {}
        valid = properties.each_slice(3).all? do |key, separator, property|
          key = key.downcase
          separator == "=" && !attributes.key?(key) && (attributes[key] = property)
        end
        next unless valid
        method, result = method.downcase, result.to_s.downcase
        if method == "dmarc"
          result = "none" unless same_domain?(attributes["header.from"], from_domain)
        elsif method == "dkim"
          domains = []
          domains << attributes["header.d"] if attributes.key?("header.d")
          domains << attributes["header.i"].split("@").last if attributes.key?("header.i")
          result = "none" if domains.empty? || !domains.all? { |domain| same_domain?(domain, from_domain) }
        end
        [ method, result ]
      end
      first = ->(method) { results.find { |m, _| m == method }&.last }
      dkim = results.any? { |m, r| m == "dkim" && r == "pass" } ? "pass" : first.("dkim")
      new(dmarc: limit(first.("dmarc"), %w[pass fail]), spf: limit(first.("spf"), SPF_RESULTS),
          dkim: limit(dkim, %w[pass fail]), source: "authentication-results")
    end

    def same_domain?(domain, from_domain)
      from_domain.present? && domain.to_s.casecmp?(from_domain)
    end

    def host_matches?(host, suffixes)
      return false unless host&.match?(/\A[a-z0-9.-]+\z/i)
      suffixes.any? { |suffix| host.casecmp?(suffix) || host.downcase.end_with?(".#{suffix}") }
    end

    def received_hosts(value)
      tokens = result_tokens(value.to_s)&.first || []
      by = tokens.index { |token| token.casecmp?("by") }
      return [] unless tokens.first&.casecmp?("from") && by && by > 1
      [ tokens[1], tokens[by + 1] ]
    end

    # RFC 8601: semicolons and equals signs are delimiters only outside quoted strings and nested
    # comments. Keep quoted local parts joined to their domain; honor quoted pairs in both contexts.
    # Malformed quoting/comments fail closed rather than exposing their contents as method results.
    def result_tokens(value, first_only: false)
      segments = [ [] ]
      token = +""
      depth = 0
      quoted = escaped = false
      flush = -> { segments.last << token.dup unless token.empty?; token.clear }
      value.each_char do |char|
        if escaped
          token << char if depth.zero?
          escaped = false
        elsif char == "\\" && (quoted || depth.positive?)
          escaped = true
        elsif depth.positive?
          depth += 1 if char == "("
          depth -= 1 if char == ")"
        elsif char == '"'
          quoted = !quoted
        elsif quoted
          token << char
        elsif char == "("
          flush.call
          depth = 1
        elsif char == ")"
          return nil
        elsif char == ";"
          flush.call
          return segments if first_only
          segments << []
        elsif char == "="
          flush.call
          segments.last << char
        elsif char.match?(/\s/)
          flush.call
        else
          token << char
        end
      end
      return nil if quoted || escaped || depth.positive?
      flush.call
      segments
    end

    def from_provider_signals(fields, from_domain)
      received_spf = fields.find { |name, _| name == "x-mailroom-received-spf" }&.last
      spam_tests = fields.find { |name, _| name == "x-mailroom-spam-tests" }&.last
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
      # Read the identifier separately so malformed later results cannot make us skip the topmost
      # trusted header in favor of a lower copy. The first semicolon terminates the identifier.
      result_tokens(value, first_only: true)&.first&.first.to_s.downcase
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
