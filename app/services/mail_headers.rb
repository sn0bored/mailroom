# Read raw headers before the Mail gem collapses singleton fields such as From.
module MailHeaders
  # [name, value] pairs in the order they appear, folded lines joined.
  def self.fields(raw)
    head = raw.to_s.b.split(/\r?\n\r?\n/, 2).first.to_s
    head.each_line.with_object([]) do |line, fields|
      if line.match?(/\A[ \t]/)
        fields.last[1] = "#{fields.last[1]} #{line.strip}" if fields.any?
      elsif (separator = line.index(":"))
        fields << [ line[0, separator].strip.downcase, line[(separator + 1)..].strip ]
      end
    end
  end
end
