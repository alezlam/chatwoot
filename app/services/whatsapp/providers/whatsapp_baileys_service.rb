#######################################
# Unofficial WhatsApp Web provider backed by the Baileys sidecar (baileys/server.mjs).
# The number is linked by scanning a QR code, like WhatsApp Web, instead of Meta credentials.
# Inbound events arrive on /webhooks/whatsapp/:phone_number in the 360dialog payload shape,
# so Whatsapp::IncomingMessageService processes them unchanged.
# There are no message templates and no 24-hour reply window on this provider.
######################################
class Whatsapp::Providers::WhatsappBaileysService < Whatsapp::Providers::BaseService
  def send_message(phone_number, message)
    @message = message
    attachment = message.attachments.first
    return send_payload(phone_number, text_payload(message), message) if attachment.blank?

    send_payload(phone_number, attachment_payload(attachment, message), message)
  end

  def send_template(_phone_number, _template_info, message)
    message&.update!(status: :failed, external_error: I18n.t('errors.whatsapp.baileys_templates_unsupported'))
    nil
  end

  def sync_templates
    whatsapp_channel.update(message_templates: [], message_templates_last_updated: Time.now.utc)
  end

  # No credentials to check: the number is linked later by scanning the QR code.
  def validate_provider_config?
    true
  end

  def api_headers
    { 'Authorization' => "Bearer #{api_key}", 'Content-Type' => 'application/json' }
  end

  def media_url(media_id)
    "#{session_url}/media/#{media_id}"
  end

  def start_session
    response = HTTParty.put(session_url, headers: api_headers, body: { webhook_url: webhook_url }.to_json)
    raise "Baileys session start failed: #{response.code} #{response.body}" unless response.success?

    response.parsed_response
  end

  def session_status
    response = HTTParty.get(session_url, headers: api_headers)
    raise "Baileys session status failed: #{response.code} #{response.body}" unless response.success?

    response.parsed_response
  end

  def logout_session
    HTTParty.delete(session_url, headers: api_headers)
  rescue StandardError => e
    # Runs from before_destroy: never block an inbox delete because the sidecar is down.
    Rails.logger.error "[WHATSAPP BAILEYS] Logout failed for channel #{whatsapp_channel.id}: #{e.message}"
  end

  private

  def send_payload(phone_number, payload, message)
    response = HTTParty.post("#{session_url}/messages", headers: api_headers, body: payload.merge(to: phone_number).to_json)
    process_response(response, message)
  end

  # Interactive buttons/lists are not available on WhatsApp Web, so input_select is sent as numbered text.
  def text_payload(message)
    text = message.outgoing_content
    if message.content_type == 'input_select'
      options = message.content_attributes['items'].to_a.each_with_index.map { |item, index| "#{index + 1}. #{item['title']}" }
      text = [text, *options].compact_blank.join("\n")
    end
    { type: 'text', text: text }
  end

  def attachment_payload(attachment, message)
    type = %w[image audio video].include?(attachment.file_type) ? attachment.file_type : 'document'
    {
      type: type,
      url: attachment.download_url,
      caption: type == 'audio' ? nil : message.outgoing_content,
      filename: attachment.file.filename.to_s,
      mime_type: attachment.file.content_type
    }
  end

  def error_message(response)
    response.parsed_response.try(:dig, 'error', 'message')
  end

  def session_url
    "#{ENV.fetch('BAILEYS_API_URL', 'http://localhost:4100')}/sessions/#{whatsapp_channel.id}"
  end

  def webhook_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/whatsapp/#{whatsapp_channel.phone_number}"
  end

  def api_key
    ENV.fetch('BAILEYS_API_KEY')
  end
end
