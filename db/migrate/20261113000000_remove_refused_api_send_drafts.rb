# Earlier versions stored every POST /api/v1/send before checking the sending rules, so a refused
# request stayed behind as a draft: it showed up in the owner's Drafts list, and retrying its
# idempotency key returned 200 instead of the refusal. API sends are never drafts now, so remove
# those leftovers. Owner and agent drafts have no API key or a different kind and are untouched.
class RemoveRefusedApiSendDrafts < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      DELETE FROM outbound_messages
      WHERE kind = 'api' AND status = 'draft' AND api_key_id IS NOT NULL
    SQL
  end

  def down
    # The removed rows were refused requests; there is nothing to restore.
  end
end
