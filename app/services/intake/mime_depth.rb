module Intake
  # The pre-scan is a cheap first gate. enforce! is authoritative: it drives Mail's lazy body
  # parser one level at a time, checking depth before each multipart split.
  module MimeDepth
    class MimeTooDeep < StandardError; end

    BOUNDARY = /\bboundary(?:\*\d*\*?)?\s*=/i

    def self.call(source, limit:)
      open = []
      deepest = 0
      headers = []
      source.to_s.b.each_line do |raw_line|
        line = raw_line.chomp("\n")
        if line.start_with?("--") && (index = open.rindex { |boundary| boundary[:delimiter].match?(line) })
          closing = open[index][:close].match?(line)
          open.slice!((closing ? index : index + 1)..)
          headers = closing ? nil : []
        elsif headers
          if /\A[ \t]*\r?\z/.match?(line)
            if (boundary = boundary_in(headers))
              escaped = Regexp.escape(boundary)
              open << { delimiter: /\A--#{escaped}(?:--)?[ \t]*\r?\z/, close: /\A--#{escaped}--[ \t]*\r?\z/ }
              deepest = [ deepest, open.size ].max
              return deepest if deepest > limit
            end
            headers = nil
          elsif line.start_with?(" ", "\t") && headers.any?
            headers[-1] << " " << line.strip
          else
            headers << line.strip
          end
        end
      end
      deepest
    end

    def self.boundary_in(headers)
      content_type = headers.find { |header| /\AContent-Type:/i.match?(header) }
      return unless content_type && BOUNDARY.match?(content_type)

      # Parse only the field, never a body. Reuse Mail's quoted and RFC 2231 parameter decoding.
      field = Mail::ContentTypeField.new(content_type.split(":", 2).last.strip)
      field.parameters["boundary"].presence if field.main_type.to_s.casecmp?("multipart")
    rescue StandardError
      nil # Malformed or unrecognised headers still go through enforce!.
    end
    private_class_method :boundary_in

    def self.enforce!(mail, limit:)
      pending = [ [ mail, 0 ] ]
      until pending.empty?
        part, depth = pending.pop
        next unless part.multipart?
        raise MimeTooDeep if depth >= limit

        # Mail::Body#split! creates immediate children; their bodies remain lazy. Walking them
        # here bounds parsing before MessageBuilder's recursive text/HTML/attachment searches.
        part.parts.reverse_each { |child| pending << [ child, depth + 1 ] }
      end
    end
  end
end
