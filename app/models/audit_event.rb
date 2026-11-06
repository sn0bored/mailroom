# Metadata only: who did what to which record, and whether it worked. Never bodies or arguments.
class AuditEvent < ApplicationRecord
  validates :action, presence: true
  scope :newest_first, -> { order(created_at: :desc) }
end
