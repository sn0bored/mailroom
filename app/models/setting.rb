class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  def self.get(key) = find_by(key: key.to_s)&.value
  def self.set(key, value) = find_or_initialize_by(key: key.to_s).tap { |s| s.update!(value: value) }
end
