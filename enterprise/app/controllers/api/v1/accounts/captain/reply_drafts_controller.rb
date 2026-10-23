class Api::V1::Accounts::Captain::ReplyDraftsController < Api::V1::Accounts::BaseController
  before_action -> { check_authorization(Captain::ReplyDraft) }
  before_action :set_reply_draft, only: [:send_reply, :destroy]

  def index
    @reply_drafts = Captain::ReplyDraft.where(account_id: Current.account.id)
                                       .joins(:conversation)
                                       .where(conversations: { inbox_id: Current.user.assigned_inboxes.select(:id) })
                                       .includes(:conversation, :product)
                                       .order(updated_at: :desc)
  end

  # The row lock makes a second Send (two tabs, a retry) wait, then find the draft gone and get 409.
  # Message and draft deletion commit together, so a failed message keeps the draft.
  def send_reply
    @reply_draft.with_lock do
      @message = Messages::MessageBuilder.new(
        Current.user, @reply_draft.conversation, { content: params[:content].presence || @reply_draft.content }
      ).perform
      @reply_draft.destroy!
    end
    render 'api/v1/accounts/conversations/messages/create'
  rescue ActiveRecord::RecordNotFound
    head :conflict
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def destroy
    @reply_draft.destroy!
    head :no_content
  end

  private

  def set_reply_draft
    @reply_draft = Captain::ReplyDraft.where(account_id: Current.account.id).find(params[:id])
    authorize @reply_draft.conversation.inbox, :show?
  end
end
