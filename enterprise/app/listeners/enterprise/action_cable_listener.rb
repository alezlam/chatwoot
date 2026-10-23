module Enterprise::ActionCableListener
  include Events::Types
  def copilot_message_created(event)
    copilot_message = event.data[:copilot_message]
    copilot_thread = copilot_message.copilot_thread
    account = copilot_thread.account
    user = copilot_thread.user

    broadcast(account, [user.pubsub_token], COPILOT_MESSAGE_CREATED, copilot_message.push_event_data)
  end

  def captain_reply_draft_updated(event)
    draft = event.data[:reply_draft]
    broadcast(draft.account, reply_draft_tokens(draft), CAPTAIN_REPLY_DRAFT_UPDATED, draft.push_event_data)
  end

  def captain_reply_draft_deleted(event)
    draft = event.data[:reply_draft]
    broadcast(draft.account, reply_draft_tokens(draft), CAPTAIN_REPLY_DRAFT_DELETED, draft.deleted_event_data)
  end

  private

  def reply_draft_tokens(draft)
    user_tokens(draft.account, draft.conversation.inbox.members)
  end
end
