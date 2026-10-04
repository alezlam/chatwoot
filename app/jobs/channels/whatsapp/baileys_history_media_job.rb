# Attaches the media of a message imported from a WhatsApp Web (baileys) history sync. The sidecar keeps the
# message's media key in memory, so this runs shortly after the import; a missing entry (sidecar restarted)
# leaves the text placeholder in place.
class Channels::Whatsapp::BaileysHistoryMediaJob < ApplicationJob
  queue_as :low

  FILE_TYPES = { 'image' => :image, 'audio' => :audio, 'video' => :video }.freeze

  def perform(inbox_id, source_id, media_type)
    inbox = Inbox.find(inbox_id)
    message = inbox.messages.find_by(source_id: source_id)
    return if message.blank? || message.attachments.exists?

    file = Down.download(inbox.channel.media_url(source_id), headers: inbox.channel.api_headers)
    message.attachments.create!(
      account_id: message.account_id,
      file_type: FILE_TYPES.fetch(media_type, :file),
      file: { io: file, filename: file.original_filename, content_type: file.content_type }
    )
    message.update!(content: message.content.to_s.split("\n", 2)[1].presence)
  rescue Down::NotFound
    Rails.logger.info "[WHATSAPP BAILEYS] History media #{source_id} is no longer available"
  end
end
