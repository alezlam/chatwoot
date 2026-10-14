class Webhooks::ShopeeEventsJob < MutexApplicationJob
  queue_as :default
  retry_on LockAcquisitionError, wait: 2.seconds, attempts: 8

  def perform(payload)
    channel = Channel::Shopee.find_by(shop_id: payload['shop_id'])
    return if channel.blank? || !channel.account.active?

    # ponytail: push body shape is undocumented in our captures; the sync only needs the conversation id
    # and reads everything else from the API. Fix this dig if the warning below ever fires.
    conversation_id = payload.dig('data', 'content', 'conversation_id') || payload.dig('data', 'conversation_id')
    return Rails.logger.warn("Shopee webchat push without conversation_id: #{payload.to_json}") if conversation_id.blank?

    key = format(::Redis::Alfred::SHOPEE_MESSAGE_MUTEX, shop_id: channel.shop_id, conversation_id: conversation_id)
    with_lock(key, 10.seconds) do
      Shopee::ConversationSyncService.new(channel: channel, conversation_id: conversation_id.to_s).perform
    end
  end
end
