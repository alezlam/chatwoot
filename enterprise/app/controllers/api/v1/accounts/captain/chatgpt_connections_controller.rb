class Api::V1::Accounts::Captain::ChatgptConnectionsController < Api::V1::Accounts::BaseController
  before_action -> { check_authorization(Captain::ChatgptConnection) }

  MODELS_CACHE_TTL = 10.minutes

  # status_only=1 skips the models API call (models: []), for the status notice's polling.
  def show
    @connection = Current.account.captain_chatgpt_connection || Captain::ChatgptConnection.new(account: Current.account)
    render_status(models: params[:status_only].present? ? [] : available_models)
  end

  def create
    @connection = find_or_create_connection
    return encryption_not_configured unless Chatwoot.encryption_configured?

    @connection.start_device_login!
    Captain::Chatgpt::DeviceLoginJob.perform_later(@connection.id)
    render_status
  rescue Captain::Chatgpt::AuthError, Faraday::Error => e
    error = if e.is_a?(Captain::Chatgpt::AuthError)
              { type: e.type, message: e.message }
            else
              { type: 'device_code_failed', message: "ChatGPT login request failed (#{e.class.name})" }
            end
    @connection.disconnect!(error: error.merge(at: Time.current.iso8601))
    render_status(status: :unprocessable_entity)
  end

  def update
    @connection = find_or_create_connection
    @connection.update!(model: params.require(:model))
    render_status
  end

  def destroy
    @connection = Current.account.captain_chatgpt_connection || Captain::ChatgptConnection.new(account: Current.account)
    @connection.disconnect! if @connection.persisted?
    render_status
  end

  private

  # Every response carries models: the cached list while connected, [] otherwise.
  def render_status(models: available_models, status: :ok)
    @models = models
    render :show, status: status
  end

  # Without Active Record encryption keys the tokens cannot be saved, so the login is not started.
  def encryption_not_configured
    @connection.disconnect!(error: { type: 'encryption_not_configured',
                                     message: 'Active Record encryption keys are not configured on the server',
                                     at: Time.current.iso8601 })
    render_status(status: :unprocessable_entity)
  end

  # Failures and empty lists are not cached.
  def available_models
    return [] unless @connection.connected?

    key = "captain/chatgpt_models/#{@connection.id}/#{@connection.chatgpt_account_id}"
    Rails.cache.fetch(key, expires_in: MODELS_CACHE_TTL, skip_nil: true) { Captain::Chatgpt::ModelsClient.list(@connection).presence } || []
  rescue Captain::Chatgpt::AuthError, Captain::Chatgpt::RequestError
    []
  end

  def find_or_create_connection
    Captain::ChatgptConnection.find_or_create_by!(account_id: Current.account.id)
  end
end
