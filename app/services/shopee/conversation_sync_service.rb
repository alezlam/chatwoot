# Imports the messages of one Shopee conversation that Chatwoot doesn't have yet. Runs on every webchat push,
# so it covers buyer messages, seller replies sent from the Shopee app (echoes), and missed earlier pushes.
class Shopee::ConversationSyncService
  pattr_initialize [:channel!, :conversation_id!]

  def perform
    # ponytail: imports up to the latest 50 messages; a burst of more than 50 between pushes loses the oldest.
    messages = client.messages(conversation_id)
    known = channel.inbox.messages.where(source_id: messages.map { |m| m['message_id'].to_s }).pluck(:source_id)
    messages.reject { |m| known.include?(m['message_id'].to_s) }.sort_by { |m| m['created_timestamp'].to_i }.each do |m|
      create_message(m)
    end
  end

  private

  def client
    @client ||= channel.client
  end

  def inbox
    channel.inbox
  end

  def buyer
    @buyer ||= client.conversation(conversation_id)
  end

  def contact_inbox
    @contact_inbox ||= ::ContactInboxWithContactBuilder.new(
      source_id: buyer['to_id'].to_s,
      inbox: inbox,
      contact_attributes: {
        name: buyer['to_name'].presence || "Shopee #{buyer['to_id']}",
        avatar_url: buyer['to_avatar'].presence,
        additional_attributes: { social_shopee_user_id: buyer['to_id'], social_shopee_user_name: buyer['to_name'] }
      }
    ).perform
  end

  def conversation
    @conversation ||= begin
      scope = contact_inbox.conversations.order(created_at: :desc)
      scope = scope.where.not(status: :resolved) unless inbox.lock_to_single_conversation
      scope.first || ::Conversation.create!(
        account_id: inbox.account_id, inbox_id: inbox.id, contact_id: contact_inbox.contact_id,
        contact_inbox_id: contact_inbox.id, additional_attributes: { conversation_id: conversation_id }
      )
    end
  end

  def create_message(shopee_message)
    outgoing = shopee_message['from_shop_id'].to_i == channel.shop_id
    message = build_message(shopee_message, outgoing)
    message.sender = contact_inbox.contact unless outgoing
    message.status = :delivered if outgoing
    attach_image(message, shopee_message.dig('content', 'url')) if shopee_message['message_type'] == 'image'
    message.save!
  end

  def build_message(shopee_message, outgoing)
    content, supported = message_content(shopee_message)
    at = Time.zone.at(shopee_message['created_timestamp'].to_i)

    conversation.messages.build(
      content: content,
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      message_type: outgoing ? :outgoing : :incoming,
      source_id: shopee_message['message_id'].to_s,
      content_attributes: {
        external_echo: (true if outgoing),
        is_unsupported: (true unless supported),
        shopee_item_id: (shopee_message.dig('content', 'item_id')&.to_s if shopee_message['message_type'] == 'item')
      }.compact,
      created_at: at,
      updated_at: at
    )
  end

  # [content, supported?]. Product and order cards become text so the agent still sees what was shared.
  def message_content(shopee_message)
    body = shopee_message['content'] || {}
    case shopee_message['message_type']
    when 'text' then [body['text'], true]
    when 'image' then [nil, true]
    when 'item' then ["Product: #{body['item_id']}", true]
    when 'order' then ["Order: #{body['order_sn']}", true]
    else [nil, false]
    end
  end

  def attach_image(message, url)
    file = Down.download(url)
    message.attachments.new(
      account_id: message.account_id, file_type: :image,
      file: { io: file, filename: file.original_filename || 'image.jpg', content_type: file.content_type }
    )
  rescue Down::Error => e
    Rails.logger.warn("Shopee image download failed for #{url}: #{e.message}")
    message.content_attributes = message.content_attributes.merge(is_unsupported: true)
  end
end
