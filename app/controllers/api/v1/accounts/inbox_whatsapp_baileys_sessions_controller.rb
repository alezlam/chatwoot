# Pairing for WhatsApp inboxes on the unofficial Baileys provider: start a session to get a QR code,
# poll its status until the phone is linked, or unlink the phone.
class Api::V1::Accounts::InboxWhatsappBaileysSessionsController < Api::V1::Accounts::BaseController
  before_action :fetch_channel

  rescue_from Errno::ECONNREFUSED, SocketError do
    render json: { error: 'The WhatsApp Web service (baileys) is not reachable' }, status: :service_unavailable
  end

  def show
    render json: @channel.provider_service.session_status
  end

  def create
    render json: @channel.provider_service.start_session
  end

  def destroy
    @channel.provider_service.logout_session
    head :ok
  end

  private

  def fetch_channel
    inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize inbox, :update?
    @channel = inbox.channel
    return if inbox.whatsapp? && @channel.baileys?

    render json: { error: 'Only available for WhatsApp Web (QR code) inboxes' }, status: :unprocessable_entity
  end
end
