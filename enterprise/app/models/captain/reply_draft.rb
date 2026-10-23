# == Schema Information
#
# Table name: captain_reply_drafts
#
#  id              :bigint           not null, primary key
#  content         :text             not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  assistant_id    :bigint           not null
#  conversation_id :bigint           not null
#  last_message_id :bigint           not null
#  product_id      :bigint
#
# Indexes
#
#  index_captain_reply_drafts_on_account_id       (account_id)
#  index_captain_reply_drafts_on_assistant_id     (assistant_id)
#  index_captain_reply_drafts_on_conversation_id  (conversation_id) UNIQUE
#  index_captain_reply_drafts_on_product_id       (product_id)
#
class Captain::ReplyDraft < ApplicationRecord
  self.table_name = 'captain_reply_drafts'

  belongs_to :account
  belongs_to :conversation, class_name: '::Conversation'
  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :product, class_name: 'Captain::Product', optional: true

  after_commit :dispatch_updated, on: [:create, :update]
  after_commit :dispatch_deleted, on: :destroy

  def push_event_data
    {
      id: id,
      conversation_id: conversation_id,
      inbox_id: conversation.inbox_id,
      product_id: product_id,
      product_name: product&.name,
      content: content,
      updated_at: updated_at.to_i
    }
  end

  private

  def dispatch_updated
    Rails.configuration.dispatcher.dispatch(Events::Types::CAPTAIN_REPLY_DRAFT_UPDATED, Time.zone.now, reply_draft: self)
  end

  def dispatch_deleted
    Rails.configuration.dispatcher.dispatch(Events::Types::CAPTAIN_REPLY_DRAFT_DELETED, Time.zone.now, reply_draft: self)
  end
end
