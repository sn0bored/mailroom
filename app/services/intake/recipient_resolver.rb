module Intake
  # Works out which of our addresses a message was really sent to.
  #
  # With registrar catch-all forwarding the SMTP envelope recipient at the provider is the
  # provider's own inbound address, and the Rails Postmark ingress prepends that as
  # X-Original-To. The registrar's forwarder leaves its own X-Original-To and
  # "Received: ... for <addr>" lines behind. So: ignore the provider's address, keep only domains
  # we own, and prefer envelope-type headers over To/Cc.
  #
  # Envelope headers are read from the top of the message down. Every hop prepends, so the top was
  # written last, by the hops nearest us; anything the sender wrote sits below the first hop that
  # received it. The first owned envelope address from the top wins, so a Delivered-To the sender
  # planted can't beat the ingress's or the forwarder's own headers and move mail to another domain.
  #
  # A domain that keeps a hosted catch-all mailbox and auto-forwards it here is different: the
  # host stamps that mailbox on everything (Delivered-To, its last Received hop), so every message
  # first resolves to it. When a domain names that mailbox, look past it on the same domain.
  class RecipientResolver
    ENVELOPE_HEADERS = %w[Delivered-To X-Original-To X-Forwarded-To Envelope-To X-Envelope-To].freeze
    ADDRESS_HEADERS = %w[To Cc Resent-To].freeze
    # Headers a receiving host writes with the recipient it saw before its own aliasing: Postfix
    # X-Original-To, Google X-Gm-Original-To, Fastmail X-Delivered-To, Exim Envelope-To, and an
    # earlier hop's Delivered-To. Read only to look past a catch-all mailbox. Not X-Forwarded-To or
    # X-Sieve-Redirected-From: those name the forwarding mailbox or its destination, never the
    # original recipient.
    ORIGINAL_RECIPIENT_HEADERS = %w[X-Original-To X-Gm-Original-To X-Delivered-To Envelope-To X-Envelope-To Delivered-To].freeze
    RECEIVED_FOR = /\bfor\s+<?([^\s<>;,]+@[^\s<>;,]+)>?/i
    RECEIVED_FOR_LIST = /\bfor\s+((?:<?[^\s<>;,()@]+@[^\s<>;,()@]+>?[\s,]*)+)/i
    ADDRESS = /[A-Z0-9._%+'-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
    RECEIVED_BY = /(?:\A|[\s(])by\s+([^\s;()]+)/i
    # A message to thousands of our addresses should not store thousands of matches.
    MAX_MATCHES = 50
    MAX_TRACE = 100

    Result = Struct.new(:primary, :routed_via, :matches, :trace, keyword_init: true) do
      def unrouted? = primary.nil?
    end

    # catch_all_mailboxes: { mailbox => MX host or nil }, or a plain list of mailboxes.
    def self.call(mail, owned_names: Domain.owned_names, catch_all_mailboxes: Domain.catch_all_mailboxes)
      new(mail, owned_names, catch_all_mailboxes).call
    end

    def initialize(mail, owned_names, catch_all_mailboxes = {})
      @mail = mail
      @owned = owned_names.map { |n| n.to_s.downcase }
      pairs = catch_all_mailboxes.is_a?(Hash) ? catch_all_mailboxes.to_a : catch_all_mailboxes.map { |mailbox| [ mailbox, nil ] }
      @catch_all = pairs.to_h { |mailbox, host| [ mailbox.to_s.strip.downcase, host.to_s.strip.downcase.presence ] }
    end

    def call
      result = resolve
      @catch_all.key?(result.primary) ? look_past_catch_all_mailbox(result) : result
    end

    private

    def resolve
      envelope = fields_in_document_order.flat_map do |name, value|
        if name.casecmp?("Received")
          received_after_by(value).scan(RECEIVED_FOR).flatten.map { |address| [ "Received", address.downcase ] }
        elsif (header = ENVELOPE_HEADERS.find { |known| known.casecmp?(name) })
          extract(value).map { |address| [ header, address ] }
        else
          []
        end
      end
      addressed = ADDRESS_HEADERS.flat_map { |name| addresses_in(name) }
      trace = as_hashes((envelope + addressed).first(MAX_TRACE))

      owned_envelope = envelope.select { |_, a| owned?(a) }
      owned_addressed = addressed.select { |_, a| owned?(a) }
      matches = (owned_envelope + owned_addressed).map(&:last).uniq.first(MAX_MATCHES)

      if (hit = owned_envelope.first)
        Result.new(primary: hit[1], routed_via: "hdr:#{envelope_label(hit[1], owned_envelope)}", matches: matches, trace: trace)
      elsif (hit = owned_addressed.first)
        Result.new(primary: hit[1], routed_via: "to:#{hit[0]}", matches: matches, trace: trace)
      else
        Result.new(primary: nil, routed_via: "unrouted", matches: [], trace: trace)
      end
    end

    # The address comes from position; the label names the most specific envelope header that
    # carries it, so registrar mail still reads hdr:X-Original-To even when its forwarder's
    # Received line sits above that header.
    def envelope_label(address, owned_envelope)
      ranked = ENVELOPE_HEADERS + [ "Received" ]
      owned_envelope.select { |_, a| a == address }.map(&:first).min_by { |header| ranked.index(header) }
    end

    # Same domain only, so the domain decision never changes.
    #
    # First the trace fields (original-recipient headers and single-recipient Received hops), read
    # from the top down, so the host's own hops count before anything the sender wrote below them.
    # The mailbox is skipped there because the host writes it on everything itself. Then To, Cc,
    # Resent-To, where the mailbox counts.
    #
    # Without an MX host the scan cannot tell where the host's hops end, so it keeps reading below
    # the MX hop. Two accepted residuals follow, both confined to the mailbox's own domain and no
    # worse than a forged To: mail really sent to the mailbox can be relabelled by a trace header
    # the sender planted below the MX hop, and so can mail whose MX hop names several recipients.
    #
    # With the domain's MX host set, the topmost Received by that host is the MX hop and is final:
    # its single "for" wins even when it names the mailbox, and nothing below it is read. If it
    # names no single recipient, only the host-written fields above it count, then To/Cc. If no
    # hop matches, or it names an address off this domain, the mailbox stays (fail closed).
    def look_past_catch_all_mailbox(result)
      mailbox = result.primary
      domain = domain_of(mailbox)
      mx_host = @catch_all[mailbox]
      fields = trace_fields
      trace = result.trace + [ { "header" => "catch_all_mailbox", "address" => mailbox } ]

      if mx_host
        mx_index = fields.index { |header, _, by_hosts| header == "Received" && by_hosts.any? { |host| host_matches?(host, mx_host) } }
        if mx_index.nil?
          return keep(result, trace + [ { "header" => "catch_all_mx_host_missing", "address" => mx_host } ])
        end
        mx_for = fields[mx_index][1]
        if mx_for.size == 1
          return keep(result, trace) unless domain_of(mx_for.first) == domain
          return recovered(result, trace, "Received", mx_for.first) unless mx_for.first == mailbox
          return keep(result, trace + [ { "header" => "Received", "address" => mailbox } ])
        end
        fields = fields.first(mx_index)
      end

      hit = fields.flat_map { |header, addresses, _| addresses.map { |address| [ header, address ] } }
                  .find { |_, address| domain_of(address) == domain && address != mailbox } ||
            ADDRESS_HEADERS.flat_map { |name| addresses_in(name) }.find { |_, address| domain_of(address) == domain }
      return keep(result, trace) if hit.nil? || hit[1] == mailbox

      recovered(result, trace, *hit)
    end

    def keep(result, trace) = Result.new(**result.to_h.merge(trace: trace))

    def recovered(result, trace, header, address)
      found = { "header" => header, "address" => address }
      trace += [ found ] unless trace.include?(found)
      Result.new(primary: address, routed_via: "catch-all:#{header}",
                 matches: (result.matches + [ address ]).uniq.first(MAX_MATCHES), trace: trace)
    end

    def host_matches?(host, mx_host) = host == mx_host || host.end_with?(".#{mx_host}")

    def addresses_in(name)
      header_values(name).flat_map { |value| extract(value).map { |address| [ name, address ] } }
    end

    # [header, addresses, by-hosts] for each trace field, top down.
    def trace_fields
      fields_in_document_order.filter_map do |name, value|
        if name.casecmp?("Received")
          clean = received_tokens(value)
          [ "Received", received_for(clean), clean.scan(RECEIVED_BY).flatten.map { |host| host.downcase.chomp(".") } ]
        elsif (header = ORIGINAL_RECIPIENT_HEADERS.find { |known| known.casecmp?(name) })
          [ header, extract(value), [] ]
        end
      end
    end

    # The Mail gem regroups fields by name, which loses which hop wrote what. Read the raw header
    # block instead, unfolding continuation lines. Stray 8-bit bytes are scrubbed, not fatal.
    def fields_in_document_order
      @fields_in_document_order ||= begin
        raw = @mail.header.raw_source.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        if raw.empty?
          @mail.header.fields.map { |f| [ f.name.to_s, f.value.to_s ] }
        else
          raw.split(/\r?\n(?![ \t])/).filter_map do |field|
            name, value = field.split(":", 2)
            [ name.strip, value.gsub(/\r?\n[ \t]+/, " ").strip ] if value
          end
        end
      rescue StandardError
        []
      end
    end

    # The single recipient a Received hop names. A hop listing several recipients does not say
    # which one this copy was for, so it counts for nothing.
    def received_for(value)
      list = received_after_by(value)[RECEIVED_FOR_LIST, 1]
      addresses = list.to_s.scan(ADDRESS).map(&:downcase).uniq
      addresses.size == 1 ? addresses : []
    end

    def received_after_by(value)
      clean = received_tokens(value)
      match = RECEIVED_BY.match(clean)
      match ? clean[match.end(0)..].split(";", 2).first.to_s : ""
    end

    # Comments can nest and both comments and quoted strings allow escaped characters.
    # Replace them with whitespace so removing one cannot join two tokens into a clause.
    def received_tokens(value)
      clean = +""
      depth = 0
      quoted = false
      escaped = false
      value.each_char do |char|
        if escaped
          escaped = false
        elsif (depth.positive? || quoted) && char == "\\"
          escaped = true
        elsif depth.positive?
          depth += 1 if char == "("
          depth -= 1 if char == ")"
        elsif quoted
          quoted = false if char == '"'
        elsif char == "("
          depth = 1
          clean << " "
        elsif char == '"'
          quoted = true
          clean << " "
        else
          clean << char
        end
      end
      clean
    end

    def domain_of(address) = address.to_s.split("@").last.to_s

    def header_values(name)
      @mail.header.fields.select { |f| f.name.to_s.casecmp?(name) }.map { |f| f.value.to_s }
    rescue StandardError
      []
    end

    def extract(value)
      value.to_s.scan(ADDRESS).map(&:downcase).uniq
    end

    def owned?(address)
      domain = address.split("@").last.to_s
      return false if domain == Mailroom::POSTMARK_INBOUND_DOMAIN
      @owned.include?(domain)
    end

    def as_hashes(trace)
      trace.map { |header, address| { "header" => header, "address" => address } }
    end
  end
end
