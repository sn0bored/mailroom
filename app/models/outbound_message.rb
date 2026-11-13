class OutboundMessage < ApplicationRecord
  KINDS = %w[api reply forward_copy probe].freeze

  attribute :to_addresses, :json, default: -> { [] }
  attribute :cc_addresses, :json, default: -> { [] }
  attribute :bcc_addresses, :json, default: -> { [] }
  # draft -> queued -> sending (claimed by a delivery job) -> sent | failed
  STATUSES = %w[draft queued sending sent failed].freeze

  belongs_to :api_key, optional: true
  belongs_to :user, optional: true
  belongs_to :source_message, class_name: "Message", optional: true, inverse_of: :outbound_messages

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :from_address, presence: true
  validate :from_address_is_one_mailbox, if: :will_save_change_to_from_address?
  validate :recipients_present
  validate :api_send_is_not_a_draft

  scope :drafts, -> { where(status: "draft") }
  scope :newest_first, -> { order(created_at: :desc) }

  def draft? = status == "draft"
  def sent? = status == "sent"
  def recipients = Array(to_addresses) + Array(cc_addresses) + Array(bcc_addresses)

  # A message an app sent with POST /api/v1/send. These skip the draft stage entirely: the owner's
  # Drafts list is for messages a person reviews, never for an app's request.
  def api_send? = kind == "api" && api_key_id.present?

  # The single mailbox in from_address, or nil when it is not exactly one address with a domain.
  # "Name <sender@example.org>" is one mailbox: the display name stays in from_address for the
  # delivered header, and the sending rules look only at the domain.
  def from_mailbox
    list = Mail::AddressList.new(from_address.to_s)
    mailbox = list.addresses.first if list.addresses.one? && list.group_names.empty?
    mailbox if mailbox&.domain.present?
  rescue Mail::Field::ParseError
    nil
  end

  def from_domain = from_mailbox&.domain.to_s.downcase

  # True when this reply goes to the source message's Reply-To and that is not the address the
  # message came from: the sender chose where the answer goes, so the owner is told.
  def reply_to_differs_from_sender?
    return false unless source_message

    reply_to = source_message.reply_to.to_s.strip
    return false if reply_to.empty? || reply_to.casecmp?(source_message.from_address.to_s.strip)

    Array(to_addresses).any? { |address| address.to_s.strip.casecmp?(reply_to) }
  end

  private

  def from_address_is_one_mailbox
    return if from_address.blank? || from_mailbox

    errors.add(:from_address, "must be one email address, optionally with a display name")
  end

  def recipients_present
    errors.add(:to_addresses, "must include at least one address") if Array(to_addresses).reject(&:blank?).empty?
  end

  def api_send_is_not_a_draft
    errors.add(:status, "cannot be draft for a message sent through the API") if api_send? && draft?
  end
end
