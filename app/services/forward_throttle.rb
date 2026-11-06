require "digest"

class ForwardThrottle
  def self.allow?(from_address)
    key = "forward-throttle:#{Digest::SHA256.hexdigest(from_address.to_s.strip.downcase)}"
    count = Rails.cache.increment(key, 1, expires_in: 1.hour)
    count.to_i <= ForwardCopyJob::FORWARD_COPIES_PER_SENDER_PER_HOUR
  end
end
