module Intake
  # Works out which of our addresses a message was really sent to.
  #
  # With registrar catch-all forwarding the SMTP envelope recipient at the provider is the
  # provider's own inbound address, and the Rails Postmark ingress prepends that as
  # X-Original-To. The registrar's forwarder leaves its own X-Original-To and
  # "Received: ... for <addr>" lines behind. So: collect every candidate, ignore the
  # provider's address, keep only domains we own, prefer envelope-type headers over To/Cc.
  class RecipientResolver
    ENVELOPE_HEADERS = %w[Delivered-To X-Original-To X-Forwarded-To Envelope-To X-Envelope-To].freeze
    ADDRESS_HEADERS = %w[To Cc Resent-To].freeze
    RECEIVED_FOR = /\bfor\s+<?([^\s<>;,]+@[^\s<>;,]+)>?/i
    ADDRESS = /[A-Z0-9._%+'-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i

    Result = Struct.new(:primary, :routed_via, :matches, :trace, keyword_init: true) do
      def unrouted? = primary.nil?
    end

    def self.call(mail, owned_names: Domain.owned_names)
      new(mail, owned_names).call
    end

    def initialize(mail, owned_names)
      @mail = mail
      @owned = owned_names.map { |n| n.to_s.downcase }
    end

    def call
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

    private

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
