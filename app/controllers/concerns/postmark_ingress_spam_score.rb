# Rails' Postmark ingress keeps only the RawEmail field. Postmark's spam score also arrives in the JSON
# Headers array, which lists Postmark's own headers first. Mailroom always writes that score into a
# header it owns at the very top of the stored message ("none" when Postmark gave no score), so an
# X-Spam-Score the sender wrote, in the headers or as a body line, never stands in for it.
module PostmarkIngressSpamScore
  SCORE = /\A-?\d+(\.\d+)?\z/

  def mail
    super.tap { |raw| raw.prepend("X-Mailroom-Spam-Score: ", postmark_spam_score, "\n") }
  end

  private

  def postmark_spam_score
    header = Array(params[:Headers]).map { |h| h.respond_to?(:to_unsafe_h) ? h.to_unsafe_h : h }
                                    .find { |h| h.is_a?(Hash) && h["Name"].to_s.casecmp?("X-Spam-Score") }
    score = header&.dig("Value").to_s.strip
    score.match?(SCORE) ? score : "none"
  end
end
