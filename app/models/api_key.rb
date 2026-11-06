require "digest"

class ApiKey < ApplicationRecord
  SCOPES = %w[mail:read mail:write mail:draft mail:send].freeze
  PREFIX = "mr".freeze

  attribute :scopes, :json, default: -> { [] }
  attribute :allowed_from_domains, :json, default: -> { [] }

  has_many :outbound_messages, dependent: :nullify

  validates :name, presence: true
  validates :token_prefix, :token_digest, presence: true
  validate :scopes_known

  scope :active, -> { where(revoked_at: nil) }

  # Returns [record, plaintext]. The plaintext is shown once and never stored.
  def self.generate(name:, scopes:, allowed_from_domains: [])
    prefix = SecureRandom.base58(8)
    plaintext = "#{PREFIX}_#{prefix}_#{SecureRandom.base58(32)}"
    record = create!(name: name, scopes: Array(scopes).map(&:to_s),
                     allowed_from_domains: Array(allowed_from_domains).map { |d| d.to_s.downcase },
                     token_prefix: prefix, token_digest: digest(plaintext))
    [ record, plaintext ]
  end

  def self.authenticate(plaintext)
    return nil if plaintext.blank?
    key = active.find_by(token_digest: digest(plaintext))
    key&.update_column(:last_used_at, Time.current)
    key
  end

  def self.digest(plaintext) = Digest::SHA256.hexdigest(plaintext.to_s)

  def active? = revoked_at.nil?
  def allows?(scope) = active? && scopes.include?(scope.to_s)
  def may_send_from?(domain_name) = allowed_from_domains.blank? || allowed_from_domains.include?(domain_name.to_s.downcase)
  def revoke! = update!(revoked_at: Time.current)
  def label = "#{PREFIX}_#{token_prefix}_..."

  private

  def scopes_known
    unknown = Array(scopes) - SCOPES
    errors.add(:scopes, "unknown: #{unknown.join(', ')}") if unknown.any?
    errors.add(:scopes, "can't be empty") if Array(scopes).empty?
  end
end
