class Shopee::SendOnShopeeService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Shopee
  end

  def perform_reply
    # ponytail: text only; images need sellerchat/upload_image first, add when agents need to send them.
    raise 'Sending attachments is not supported on Shopee yet.' if message.attachments.any?

    response = channel.client.send_text(contact_inbox.source_id, message.outgoing_content)
    message.update!(source_id: response['message_id'].to_s)
    Messages::StatusUpdateService.new(message, 'delivered').perform
  rescue StandardError => e
    mark_failed(e)
  end

  def mark_failed(error)
    channel.authorization_error! if error.is_a?(Shopee::Client::Error) && error.auth_error?
    Rails.logger.error "Failed to send Shopee message: #{error.message}"
    Messages::StatusUpdateService.new(message, 'failed', error.message).perform
  end
end
