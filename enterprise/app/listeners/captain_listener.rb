class CaptainListener < BaseListener
  include ::Events::Types

  EXTRAS_ENABLED = false

  def message_updated(event)
    message = event.data[:message]
    return unless message.input_csat?

    response = CsatSurveyResponse.find_by(message: message)
    return unless response

    tracker(message.conversation).record_csat(response: response)
  end

  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    tracker(conversation).record_resolution(at: event.timestamp)

    assistant = conversation.inbox.captain_assistant

    return unless conversation.inbox.captain_active?

    # ponytail: FAQ generation and contact memory need an OpenAI API key; wait for the ChatGPT provider.
    return unless EXTRAS_ENABLED

    Captain::Llm::ContactNotesService.new(assistant, conversation).generate_and_update_notes if assistant.config['feature_memory'].present?
    Captain::Llm::ConversationFaqJob.perform_later(conversation, assistant) if assistant.config['feature_faq'].present?
  end

  private

  def tracker(conversation)
    Captain::ConversationOutcomeTracker.new(conversation: conversation)
  end
end
