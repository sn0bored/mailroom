class OutboundMessage < ApplicationRecord
  KINDS = %w[api reply forward_copy probe].freeze

  attribute :to_addresses, :json, default: -> { [] }
  attribute :cc_addresses, :json, default: -> { [] }
  attribute :bcc_addresses, :json, default: -> { [] }
  STATUSES = %w[draft queued sent failed].freeze

  belongs_to :api_key, optional: true
  belongs_to :user, optional: true
  belongs_to :source_message, class_name: "Message", optional: true, inverse_of: :outbound_messages

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :from_address, presence: true
  validate :recipients_present

  scope :drafts, -> { where(status: "draft") }
  scope :newest_first, -> { order(created_at: :desc) }

  def draft? = status == "draft"
  def sent? = status == "sent"
  def from_domain = from_address.to_s.split("@").last.to_s.downcase
  def recipients = Array(to_addresses) + Array(cc_addresses) + Array(bcc_addresses)

  private

  def recipients_present
    errors.add(:to_addresses, "must include at least one address") if Array(to_addresses).reject(&:blank?).empty?
  end
end
