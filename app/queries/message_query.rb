# One filter vocabulary for the agent surface and the owner UI.
class MessageQuery
  MAX_LIMIT = 100
  DEFAULT_LIMIT = 25

  def initialize(params = {}, default_limit: DEFAULT_LIMIT)
    @p = (params || {}).to_h.with_indifferent_access
    @default_limit = default_limit
  end

  def resolve
    scope = Message.newest_first
    scope = truthy?(@p[:archived]) ? scope.archived : scope.inbox
    if @p[:domain].present?
      scope = scope.joins(:domain).where(domains: { name: @p[:domain].to_s.strip.downcase })
    end
    scope = scope.unrouted if truthy?(@p[:unrouted])
    scope = scope.unread if truthy?(@p[:unread])
    scope = scope.search(@p[:q].to_s.first(200)) if @p[:q].present?
    scope = scope.where("messages.received_at >= ?", Time.iso8601(@p[:since].to_s)) if @p[:since].present?
    scope = scope.where("messages.id < ?", Integer(@p[:before_id])) if @p[:before_id].present?
    scope.limit(limit)
  end

  def limit
    raw = @p[:limit].present? ? Integer(@p[:limit]) : @default_limit
    raw.clamp(1, MAX_LIMIT)
  end

  private

  def truthy?(value)
    [ true, "true", "1", 1, "yes" ].include?(value)
  end
end
