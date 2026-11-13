module Intake
  # How deeply a raw message nests multipart bodies, read without parsing it. The Mail gem parses
  # parts recursively: a few hundred levels cost seconds and a few thousand overflow the stack.
  #
  # Counts boundaries open at once. A boundary= parameter on a header line opens one; its closing
  # delimiter (--boundary--) closes it and anything opened inside it. Stops counting past the limit.
  module MimeDepth
    BOUNDARY = /\A(?:Content-Type:|[ \t]).*?\bboundary\s*=\s*(?:"([^"\r\n]+)"|([^\s;"]+))/i

    def self.call(source, limit:)
      open = []
      deepest = 0
      source.to_s.each_line do |line|
        if line.start_with?("--")
          index = open.rindex { |boundary| line.start_with?("--#{boundary}--") }
          open.slice!(index..) if index
        elsif (match = BOUNDARY.match(line))
          open << (match[1] || match[2])
          deepest = [ deepest, open.size ].max
          break if deepest > limit
        end
      end
      deepest
    end
  end
end
