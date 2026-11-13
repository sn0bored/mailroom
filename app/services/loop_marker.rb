# Marks the mail Mailroom sends to itself or to its owner (forward copies and probes) so a copy that
# comes back is recognised as a loop. The marker is an HMAC of that message's own Message-ID under a
# key derived from secret_key_base, so it proves nothing for any other message: a value copied out of
# one copy cannot suppress the forward copy of a different message. Ordinary replies carry no marker.
module LoopMarker
  HEADER = "X-Mailroom-Loop"

  def self.stamp(message_id)
    OpenSSL::HMAC.hexdigest("SHA256", key, normalize(message_id))
  end

  def self.valid?(message_id, marker)
    return false if marker.blank? || normalize(message_id).blank?
    ActiveSupport::SecurityUtils.secure_compare(stamp(message_id), marker.to_s.strip)
  end

  def self.normalize(message_id)
    message_id.to_s.strip.delete_prefix("<").delete_suffix(">")
  end

  def self.key
    Rails.application.key_generator.generate_key("mailroom loop marker #{Mailroom.instance_id}", 32)
  end
  private_class_method :normalize, :key
end
