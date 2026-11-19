# Rails' Postmark ingress keeps only RawEmail. Postmark's JSON Headers array lists its own signals
# first. Copy the spam score and sender checks into owned headers at the top of the stored message,
# stamping "none" when absent, so sender-writable raw headers cannot stand in for provider signals.
module PostmarkIngressSpamScore
  SCORE = /\A-?\d+(\.\d+)?\z/

  def mail
    super.tap do |raw|
      raw.prepend("X-Mailroom-Spam-Score: #{postmark_spam_score}\n" \
        "X-Mailroom-Spam-Tests: #{postmark_header('X-Spam-Tests')}\n" \
        "X-Mailroom-Received-SPF: #{postmark_header('Received-SPF')}\n")
    end
  end

  private

  def postmark_spam_score
    score = postmark_header("X-Spam-Score")
    score.match?(SCORE) ? score : "none"
  end

  # These values come only from the authenticated JSON payload, never RawEmail. Always prepend
  # a value, including when absent, to shadow any Mailroom-owned headers a sender supplied.
  def postmark_header(name)
    header = Array(params[:Headers]).map { |h| h.respond_to?(:to_unsafe_h) ? h.to_unsafe_h : h }
                                    .find { |h| h.is_a?(Hash) && h["Name"].to_s.casecmp?(name) }
    value = header&.dig("Value").to_s
    return "none" if value.match?(/[\r\n\x00]/) || value.strip.empty?
    value.strip
  end
end
