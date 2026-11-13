class Domain < ApplicationRecord
  HOSTNAME = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

  has_many :messages, dependent: :nullify

  attribute :forward_addresses, :json, default: -> { [] }

  before_validation do
    self.name = name.to_s.strip.downcase
    self.catch_all_mailbox = catch_all_mailbox.to_s.strip.downcase.presence
    self.catch_all_mx_host = catch_all_mx_host.to_s.strip.downcase.chomp(".").presence
  end
  before_create { self.probe_token ||= SecureRandom.hex(8) }

  validates :name, presence: true, uniqueness: true,
                   format: { with: HOSTNAME, message: "must be a bare hostname such as example.org" }
  validates :forward_copy_max_spam, numericality: true
  validates :forward_mode, inclusion: { in: %w[all listed off] }
  validate :catch_all_mailbox_on_this_domain, if: :catch_all_mailbox
  validates :catch_all_mx_host, format: { with: HOSTNAME, message: "must be a bare hostname such as mx1.example.net" }, allow_nil: true
  validates :catch_all_mx_host, absence: { message: "needs a hosted catch-all mailbox" }, unless: :catch_all_mailbox

  scope :active, -> { where(active: true) }

  def self.owned_names = active.pluck(:name)
  # { mailbox => MX host or nil } for the resolver.
  def self.catch_all_mailboxes = active.where.not(catch_all_mailbox: nil).pluck(:catch_all_mailbox, :catch_all_mx_host).to_h

  def self.for_address(address)
    host = address.to_s.split("@").last.to_s.downcase
    active.find_by(name: host) if host.present?
  end

  # Where copies of inbound mail go: the domain's own setting, then the installation default.
  def forward_target
    forward_copy_to.presence || Setting.get("default_forward_to").presence || Mailroom.default_forward_to
  end

  def forwarding? = forward_mode != "off" && forward_target.present?

  def forward_copy_for?(message)
    return false unless forwarding?
    return true if forward_mode == "all"

    local = message.to_address.to_s.split("@").first.to_s.downcase
    local.present? && Array(forward_addresses).any? do |address|
      address.to_s.strip.split("@").first.to_s.casecmp?(local)
    end
  end

  def probe_address = "probe-#{probe_token}@#{name}"
  def receiving? = last_received_at.present?

  # The one line the owner pastes at the registrar.
  def catch_all_instruction
    inbound = Mailroom.inbound_address
    return nil if inbound.blank?
    "*@#{name} -> #{inbound}"
  end

  private

  # A hosted mailbox that auto-forwards here must live on this domain, and must not also be where
  # copies go, whether set here or inherited from the default: the copy would come straight back.
  def catch_all_mailbox_on_this_domain
    local, host = catch_all_mailbox.split("@", 2)
    if local.blank? || host != name || catch_all_mailbox.match?(/\s/)
      errors.add(:catch_all_mailbox, "must be an address on this domain, such as info@#{name.presence || 'example.org'}")
    elsif catch_all_mailbox.casecmp?(forward_target.to_s.strip)
      errors.add(:catch_all_mailbox, "can't also be where copies are forwarded")
    end
  end
end
