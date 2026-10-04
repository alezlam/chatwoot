# Imports the chat history a phone sends once after it is linked to a WhatsApp Web (baileys) inbox.
#
# History is not live traffic, so messages and conversations are bulk inserted, which skips the
# model callbacks: no agent notifications, automations, assignment, webhooks or unread counts.
# Each contact gets one resolved conversation that reopens through the normal flow on a new message.
# Media is not downloaded; it is stored as a text placeholder (plus its caption).
class Whatsapp::BaileysHistoryImportService
  pattr_initialize [:inbox!, :messages!]

  def perform
    new_messages = messages.reject { |message| imported_source_ids.include?(message[:id]) }
    new_messages.group_by { |message| message[:phone].presence || message[:lid] }.each_value do |contact_messages|
      import_contact_messages(contact_messages.sort_by { |message| message[:timestamp].to_i })
    end
  end

  private

  def imported_source_ids
    @imported_source_ids ||= inbox.messages.where(source_id: messages.pluck(:id)).pluck(:source_id).to_set
  end

  def import_contact_messages(contact_messages)
    contact_inbox = resolve_contact_inbox(contact_messages)
    conversation_id = contact_inbox.conversations.order(:created_at).last&.id || insert_conversation(contact_inbox, contact_messages)
    rows = contact_messages.map { |message| message_row(message, conversation_id, contact_inbox.contact_id) }
    Message.insert_all!(rows) # rubocop:disable Rails/SkipsModelValidations
  end

  def resolve_contact_inbox(contact_messages)
    first = contact_messages.first
    ContactInboxSourceIdResolver.new(
      inbox: inbox,
      source_ids: [phone_source_id(first[:phone]), first[:lid]].compact_blank,
      contact_attributes: contact_attributes(first, contact_messages.filter_map { |message| message[:name] }.first),
      prefer_first_source_id: true
    ).perform
  end

  def phone_source_id(phone)
    return if phone.blank?

    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(phone, :cloud)
  end

  def contact_attributes(message, name)
    return { name: name.presence || message[:lid] } if message[:phone].blank?

    { name: name.presence || "+#{message[:phone]}", phone_number: "+#{message[:phone]}" }
  end

  def insert_conversation(contact_inbox, contact_messages)
    first_at = Time.zone.at(contact_messages.first[:timestamp].to_i)
    last_at = Time.zone.at(contact_messages.last[:timestamp].to_i)
    Conversation.insert!( # rubocop:disable Rails/SkipsModelValidations
      {
        account_id: inbox.account_id, inbox_id: inbox.id, contact_id: contact_inbox.contact_id, contact_inbox_id: contact_inbox.id,
        status: Conversation.statuses[:resolved], created_at: first_at, updated_at: last_at, last_activity_at: last_at,
        agent_last_seen_at: Time.current, assignee_last_seen_at: Time.current, additional_attributes: {}, custom_attributes: {}
      },
      returning: %w[id]
    ).first['id']
  end

  def message_row(message, conversation_id, contact_id)
    created_at = Time.zone.at(message[:timestamp].to_i)
    content = message_content(message)
    {
      account_id: inbox.account_id, inbox_id: inbox.id, conversation_id: conversation_id,
      message_type: Message.message_types[message[:from_me] ? :outgoing : :incoming],
      status: Message.statuses[message[:from_me] ? :delivered : :sent],
      sender_type: message[:from_me] ? nil : 'Contact', sender_id: message[:from_me] ? nil : contact_id,
      source_id: message[:id], content: content, processed_message_content: content,
      content_type: Message.content_types[:text], content_attributes: { whatsapp_history: true },
      created_at: created_at, updated_at: created_at
    }
  end

  def message_content(message)
    return message[:text] if message[:type] == 'text'

    placeholder = I18n.t('conversations.messages.whatsapp.history_media', type: message[:type])
    [placeholder, message[:text]].compact_blank.join("\n")
  end
end
