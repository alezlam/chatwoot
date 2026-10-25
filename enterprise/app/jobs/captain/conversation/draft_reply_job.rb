# Draft mode: writes one reply draft per conversation for a human to review. It never creates a message,
# never hands off and never changes the conversation, so a failure only means there is no draft.
# The agents run only on the account's ChatGPT connection; without a usable one there is no draft.
class Captain::Conversation::DraftReplyJob < ApplicationJob
  # generate_response rescues its own errors; these can come from the message history build outside it.
  retry_on ActiveStorage::FileNotFoundError, attempts: 3, wait: 2.seconds
  retry_on Faraday::BadRequestError, attempts: 3, wait: 2.seconds

  def perform(conversation, assistant, responding_to_message_id = nil)
    @conversation = conversation
    @assistant = assistant
    @responding_to_message_id = responding_to_message_id

    return if superseded?
    return unless chatgpt_ready?

    product = Captain::Products::MatchService.new(conversation: conversation, assistant: assistant).perform
    result = generate(product)
    return log_skip(result) if no_draft?(result)
    return if superseded?

    save_draft(product, result['response'])
  rescue ActiveStorage::FileNotFoundError, Faraday::BadRequestError
    raise
  rescue StandardError => e
    Rails.logger.error("[CAPTAIN][DraftReplyJob] conversation=#{conversation.id} #{e.class}: #{e.message}")
    ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
  end

  private

  def generate(product)
    run_options = Captain::Assistant::AgentRunnerService::RunOptions.new(
      source: Captain::Assistant::AgentRunnerService::DRAFT_SOURCE,
      responding_to_message_id: @responding_to_message_id,
      runtime_configuration: { draft: true, current_product: product&.slice(:name, :description, :prompt, :context) }
    )
    message_history = Captain::Conversation::MessageHistoryBuilderService.new(conversation: @conversation, draft: true).perform
    Captain::Assistant::AgentRunnerService.new(assistant: @assistant, conversation: @conversation, run_options: run_options)
                                          .generate_response(message_history: message_history)
  end

  def save_draft(product, content)
    Captain::ReplyDraft.find_or_initialize_by(conversation: @conversation).update!(
      account: @conversation.account, assistant: @assistant, product: product,
      content: content, last_message_id: @responding_to_message_id
    )
  end

  def chatgpt_ready?
    reason = chatgpt_unready_reason
    return true if reason.nil?

    Rails.logger.warn("[CAPTAIN][DraftReplyJob] No draft for conversation=#{@conversation.id}: ChatGPT not ready (#{reason})")
    false
  end

  # Connected, not rate limited, and a model to run (the first listed one when the owner picked none).
  # Agent runs rescue their own errors (UsageLimitError, AuthError included) into an error result, so only this
  # pre-run check can raise them; the connection already carries last_error for the owner and a retry cannot help.
  def chatgpt_unready_reason
    connection = @conversation.account.captain_chatgpt_connection
    return "status=#{connection&.status || 'none'}" unless connection&.connected?
    return "rate limited until #{connection.last_error['resets_at']}" if connection.rate_limited?

    "no model (#{connection.last_error['type']})" if connection.draft_model!.blank?
  rescue Captain::Chatgpt::UsageLimitError, Captain::Chatgpt::AuthError => e
    "#{e.class.name.demodulize} #{e.type}"
  end

  # A newer buyer message gets its own draft; a human reply (not automation or a bot) already answered this one.
  def superseded?
    return false if @responding_to_message_id.blank?

    Conversation.uncached do
      newer = @conversation.messages.where('messages.id > ?', @responding_to_message_id)
      newer.captain_response_triggering.exists? || newer.outgoing.where(private: false).includes(:sender).any?(&:captain_human_reply?)
    end
  end

  def no_draft?(result) = result['error'] || result['handoff_tool_called'] || result['response'].blank?

  def log_skip(result)
    Rails.logger.warn(
      "[CAPTAIN][DraftReplyJob] No draft for conversation=#{@conversation.id}: " \
      "error=#{result['error'].inspect} handoff_tool_called=#{result['handoff_tool_called'].inspect}"
    )
  end
end
