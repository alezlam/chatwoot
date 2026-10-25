class Api::V1::Accounts::Captain::ChatgptConnectionsController < Api::V1::Accounts::BaseController
  before_action -> { check_authorization(Captain::ChatgptConnection) }

  def show
    @connection = Current.account.captain_chatgpt_connection || Captain::ChatgptConnection.new(account: Current.account)
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

  def find_or_create_connection
    Captain::ChatgptConnection.find_or_create_by!(account_id: Current.account.id)
  end
end
