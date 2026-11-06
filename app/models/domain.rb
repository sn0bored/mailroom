class Domain < ApplicationRecord
  HOSTNAME = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

  has_many :messages, dependent: :nullify

  attribute :forward_addresses, :json, default: -> { [] }

  before_validation { self.name = name.to_s.strip.downcase }
  before_create { self.probe_token ||= SecureRandom.hex(8) }

  validates :name, presence: true, uniqueness: true,
                   format: { with: HOSTNAME, message: "must be a bare hostname such as example.org" }
  validates :forward_copy_max_spam, numericality: true
  validates :forward_mode, inclusion: { in: %w[all listed off] }

  scope :active, -> { where(active: true) }

  def self.owned_names = active.pluck(:name)

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
end
