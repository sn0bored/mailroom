# Earlier versions stored every POST /api/v1/send before checking the sending rules, so a refused
# request stayed behind as a draft: it showed up in the owner's Drafts list, and retrying its
# idempotency key returned 200 with status "draft". API sends are never drafts now. Mark those
# leftovers failed instead of deleting them: they leave Drafts, the rows stay for the record, and a
# replay of their key honestly reports a failed message. Owner and agent drafts are untouched.
class FailRefusedApiSendDrafts < ActiveRecord::Migration[8.0]
  class OutboundMessage < ActiveRecord::Base
    self.table_name = "outbound_messages"
  end

  def up
    OutboundMessage.where(kind: "api", status: "draft").where.not(api_key_id: nil)
      .update_all(status: "failed", error: "refused before upgrade; not sent", updated_at: Time.current)
  end

  def down
    # Nothing to undo: the rows were refused requests that were never sent.
  end
end
