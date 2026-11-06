class BlockedSender < ApplicationRecord
  before_validation { self.pattern = pattern.to_s.strip.downcase }

  validates :pattern, presence: true, uniqueness: { case_sensitive: false }
  validate :address_or_domain

  def self.blocks?(address)
    address = address.to_s.strip.downcase
    return false unless address.match?(/\A[^\s@]+@[^\s@]+\z/)

    where("LOWER(pattern) IN (?)", [ address, address.split("@").last ]).exists?
  end

  private

  def address_or_domain
    parts = pattern.to_s.split("@", -1)
    valid = parts.size == 1 && Domain::HOSTNAME.match?(parts.first.to_s)
    valid ||= parts.size == 2 && parts.first.match?(/\A[^\s@]+\z/) && Domain::HOSTNAME.match?(parts.last)
    errors.add(:pattern, "must be an email address or a bare domain") unless valid
  end
end
