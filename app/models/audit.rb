module Audit
  def self.record(action, actor: nil, target: nil, outcome: "ok", error: nil, ip: nil, duration_ms: nil)
    AuditEvent.create!(
      action: action.to_s,
      actor_type: actor&.class&.name, actor_id: actor.respond_to?(:id) ? actor.id : nil,
      target_type: target&.class&.name, target_id: target.respond_to?(:id) ? target.id : nil,
      outcome: outcome.to_s,
      error_class: error.is_a?(Class) ? error.name : error&.class&.name,
      ip: ip, duration_ms: duration_ms, created_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error("[audit] could not record #{action}: #{e.class}")
    nil
  end
end
