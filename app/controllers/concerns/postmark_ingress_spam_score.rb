# Rails' Postmark ingress keeps only the RawEmail field. Postmark normally writes its spam headers into
# the raw message too; when it does not, copy the score from the JSON Headers array so routing can see it.
module PostmarkIngressSpamScore
  def mail
    super.tap do |raw|
      next if raw.match?(/^X-Spam-Score:/i)
      score = Array(params[:Headers]).map { |h| h.respond_to?(:to_unsafe_h) ? h.to_unsafe_h : h }
                                     .find { |h| h["Name"].to_s.casecmp?("X-Spam-Score") }&.dig("Value")
      raw.prepend("X-Mailroom-Spam-Score: ", score.to_s.strip, "\n") if score.present?
    end
  end
end
