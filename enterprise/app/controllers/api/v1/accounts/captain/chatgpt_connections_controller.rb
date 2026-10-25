class Api::V1::Accounts::Captain::ChatgptConnectionsController < Api::V1::Accounts::BaseController
  before_action -> { check_authorization(Captain::ChatgptConnection) }

  MODELS_CACHE_TTL = 10.minutes

  def show
    @connection = Current.account.captain_chatgpt_connection || Captain::ChatgptConnection.new(account: Current.account)
    @models = @connection.connected? ? available_models : []
  end

  def create
    @connection = find_or_create_connection
    @connection.start_device_login!
    Captain::Chatgpt::DeviceLoginJob.perform_later(@connection.id)
    render :show
  rescue Captain::Chatgpt::AuthError, Faraday::Error => e
    error = if e.is_a?(Captain::Chatgpt::AuthError)
              { type: e.type, message: e.message }
            else
              { type: 'device_code_failed', message: "ChatGPT login request failed (#{e.class.name})" }
            end
    @connection.disconnect!(error: error.merge(at: Time.current.iso8601))
    render :show, status: :unprocessable_entity
  end

  def update
    @connection = find_or_create_connection
    @connection.update!(model: params.require(:model))
    render :show
  end

  def destroy
    @connection = Current.account.captain_chatgpt_connection || Captain::ChatgptConnection.new(account: Current.account)
    @connection.disconnect! if @connection.persisted?
    render :show
  end

  private

  # Failures and empty lists are not cached.
  def available_models
    key = "captain/chatgpt_models/#{@connection.id}/#{@connection.chatgpt_account_id}"
    Rails.cache.fetch(key, expires_in: MODELS_CACHE_TTL, skip_nil: true) { Captain::Chatgpt::ModelsClient.list(@connection).presence } || []
  rescue Captain::Chatgpt::AuthError, Captain::Chatgpt::RequestError
    []
  end

  def find_or_create_connection
    Captain::ChatgptConnection.find_or_create_by!(account_id: Current.account.id)
  end
end
