module Intake
  # Works out which of our addresses a message was really sent to.
  #
  # With registrar catch-all forwarding the SMTP envelope recipient at the provider is the
  # provider's own inbound address, and the Rails Postmark ingress prepends that as
  # X-Original-To. The registrar's forwarder leaves its own X-Original-To and
  # "Received: ... for <addr>" lines behind. So: collect every candidate, ignore the
  # provider's address, keep only domains we own, prefer envelope-type headers over To/Cc.
  #
  # A domain that keeps a hosted catch-all mailbox and auto-forwards it here is different: the
  # host stamps that mailbox on everything (Delivered-To, its last Received hop), so every message
  # first resolves to it. When a domain names that mailbox, look past it on the same domain.
  class RecipientResolver
    ENVELOPE_HEADERS = %w[Delivered-To X-Original-To X-Forwarded-To Envelope-To X-Envelope-To].freeze
    ADDRESS_HEADERS = %w[To Cc Resent-To].freeze
    # Headers a receiving host writes with the recipient it saw before its own aliasing: Postfix
    # X-Original-To, Google X-Gm-Original-To, Fastmail X-Delivered-To, Exim Envelope-To, then any
    # earlier hop's Delivered-To. Read only to look past a catch-all mailbox. Not X-Forwarded-To or
    # X-Sieve-Redirected-From: those name the forwarding mailbox or its destination, never the
    # original recipient.
    ORIGINAL_RECIPIENT_HEADERS = %w[X-Original-To X-Gm-Original-To X-Delivered-To Envelope-To X-Envelope-To Delivered-To].freeze
    RECEIVED_FOR = /\bfor\s+<?([^\s<>;,]+@[^\s<>;,]+)>?/i
    RECEIVED_FOR_LIST = /\bfor\s+((?:<?[^\s<>;,()@]+@[^\s<>;,()@]+>?[\s,]*)+)/i
    ADDRESS = /[A-Z0-9._%+'-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i

    Result = Struct.new(:primary, :routed_via, :matches, :trace, keyword_init: true) do
      def unrouted? = primary.nil?
    end

    def self.call(mail, owned_names: Domain.owned_names, catch_all_mailboxes: Domain.catch_all_mailboxes)
      new(mail, owned_names, catch_all_mailboxes).call
    end

    def initialize(mail, owned_names, catch_all_mailboxes = [])
      @mail = mail
      @owned = owned_names.map { |n| n.to_s.downcase }
      @catch_all_mailboxes = catch_all_mailboxes.map { |a| a.to_s.strip.downcase }
    end

    def call
      result = resolve
      @catch_all_mailboxes.include?(result.primary) ? look_past_catch_all_mailbox(result) : result
    end

    private

    def resolve
      trace = []
      envelope = []
      ENVELOPE_HEADERS.each do |name|
        header_values(name).each do |value|
          extract(value).each { |address| trace << [ name, address ]; envelope << [ name, address ] }
        end
      end
      header_values("Received").each do |value|
        value.scan(RECEIVED_FOR).flatten.each do |address|
          address = address.downcase
          trace << [ "Received", address ]
          envelope << [ "Received", address ]
        end
      end
      addressed = []
      ADDRESS_HEADERS.each do |name|
        header_values(name).each do |value|
          extract(value).each { |address| trace << [ name, address ]; addressed << [ name, address ] }
        end
      end

      owned_envelope = envelope.select { |_, a| owned?(a) }
      owned_addressed = addressed.select { |_, a| owned?(a) }
      matches = (owned_envelope + owned_addressed).map(&:last).uniq

      if (hit = owned_envelope.first)
        Result.new(primary: hit[1], routed_via: "hdr:#{hit[0]}", matches: matches, trace: as_hashes(trace))
      elsif (hit = owned_addressed.first)
        Result.new(primary: hit[1], routed_via: "to:#{hit[0]}", matches: matches, trace: as_hashes(trace))
      else
        Result.new(primary: nil, routed_via: "unrouted", matches: [], trace: as_hashes(trace))
      end
    end

    # Same domain only, so the domain decision never changes. Original-recipient headers first,
    # then Received "for" clauses from the oldest hop (the first host to see the sender's envelope),
    # skipping the mailbox in both because the host writes it there itself. Then To, Cc, Resent-To,
    # where the mailbox counts: mail visibly addressed to it stays with it.
    def look_past_catch_all_mailbox(result)
      mailbox = result.primary
      domain = domain_of(mailbox)
      envelope = ORIGINAL_RECIPIENT_HEADERS.flat_map { |name| addresses_in(name) }
      received = header_values("Received").reverse.flat_map { |value| received_for(value).map { |address| [ "Received", address ] } }
      visible = ADDRESS_HEADERS.flat_map { |name| addresses_in(name) }

      hit = (envelope + received).find { |_, address| domain_of(address) == domain && address != mailbox } ||
            visible.find { |_, address| domain_of(address) == domain }
      trace = result.trace + [ { "header" => "catch_all_mailbox", "address" => mailbox } ]
      return Result.new(**result.to_h.merge(trace: trace)) if hit.nil? || hit[1] == mailbox

      header, address = hit
      found = { "header" => header, "address" => address }
      trace << found unless trace.include?(found)
      Result.new(primary: address, routed_via: "catch-all:#{header}", matches: (result.matches + [ address ]).uniq, trace: trace)
    end

    def addresses_in(name)
      header_values(name).flat_map { |value| extract(value).map { |address| [ name, address ] } }
    end

    # The single recipient a Received hop names. A hop listing several recipients does not say
    # which one this copy was for, so it counts for nothing.
    def received_for(value)
      list = value[RECEIVED_FOR_LIST, 1]
      addresses = list.to_s.scan(ADDRESS).map(&:downcase).uniq
      addresses.size == 1 ? addresses : []
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
