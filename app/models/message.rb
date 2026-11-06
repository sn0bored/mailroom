class Message < ApplicationRecord
  belongs_to :inbound_email, class_name: "ActionMailbox::InboundEmail"
  belongs_to :domain, optional: true
  has_many :outbound_messages, foreign_key: :source_message_id, dependent: :nullify, inverse_of: :source_message
  has_many_attached :attachments

  attribute :matched_addresses, :json, default: -> { [] }
  attribute :routing_trace, :json, default: -> { [] }

  scope :unrouted, -> { where(domain_id: nil) }
  scope :routed, -> { where.not(domain_id: nil) }
  scope :unread, -> { where(read_at: nil) }
  scope :inbox, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :newest_first, -> { order(received_at: :desc, id: :desc) }
  scope :search, ->(q) {
    term = "%#{sanitize_sql_like(q.to_s.strip)}%"
    where("messages.from_address LIKE :t OR messages.subject LIKE :t OR messages.body_text LIKE :t", t: term)
  }

  def read? = read_at.present?
  def archived? = archived_at.present?
  def unrouted? = domain_id.nil?
  def spam?(threshold = 5.0) = spam_score.present? && spam_score >= threshold

  def display_from
    from_name.present? ? "#{from_name} <#{from_address}>" : from_address.to_s
  end

  # The full RFC 822 source as the provider delivered it (Action Mailbox keeps it as a blob).
  def raw_source = inbound_email.source

  def mark_read! = (update!(read_at: Time.current) unless read?)
  def mark_unread! = update!(read_at: nil)
  def archive! = (update!(archived_at: Time.current) unless archived?)
  def unarchive! = update!(archived_at: nil)
end
