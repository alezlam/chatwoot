class Shopee::SendOnShopeeService < Base::SendOnChannelService
  SUPPORTED_IMAGE_TYPES = %w[image/jpeg image/png].freeze

  private

  def channel_class
    Channel::Shopee
  end

  def perform_reply
    response = message.attachments.any? ? send_image : send_text
    message.update!(source_id: response['message_id'].to_s)
    Messages::StatusUpdateService.new(message, 'delivered').perform
  rescue StandardError => e
    mark_failed(e)
  end

  def send_text
    channel.client.send_text(contact_inbox.source_id, message.outgoing_content)
  end

  # One Shopee message per Chatwoot message, so the echo push dedupes on source_id.
  # The reply box already sends text and each image as separate messages.
  def send_image
    raise 'Send the text and the image as separate messages on Shopee.' if message.outgoing_content.present?
    raise 'Send one image per message on Shopee.' unless message.attachments.one?

    attachment = message.attachments.first
    raise 'Shopee chat accepts only JPG and PNG images.' unless SUPPORTED_IMAGE_TYPES.include?(attachment.file.content_type)

    client = channel.client
    image_url = attachment.file.blob.open { |file| client.upload_image(file) }
    client.send_image(contact_inbox.source_id, image_url)
  end

  def mark_failed(error)
    channel.authorization_error! if error.is_a?(Shopee::Client::Error) && error.auth_error?
    Rails.logger.error "Failed to send Shopee message: #{error.message}"
    Messages::StatusUpdateService.new(message, 'failed', error.message).perform
  end
end
