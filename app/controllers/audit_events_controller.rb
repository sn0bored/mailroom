class AuditEventsController < ApplicationController
  def index
    @events = AuditEvent.newest_first.limit(200)
  end
end
