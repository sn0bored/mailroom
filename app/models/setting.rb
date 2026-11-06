class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :value, numericality: true, if: -> { key == "inbound_spam_threshold" }

  DEFAULTS = { "inbound_spam_threshold" => "15.0" }.freeze

  def self.get(key) = find_by(key: key.to_s)&.value || DEFAULTS[key.to_s]
  def self.set(key, value) = find_or_initialize_by(key: key.to_s).tap { |s| s.update!(value: value) }
end
