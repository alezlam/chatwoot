class Captain::Chatgpt::DeviceLoginJob < ApplicationJob
  queue_as :low

  # ponytail: one run polls until the 15-minute device-code expiry, holding a worker thread that long.
  # Fine for a one-time owner login; move to a re-enqueue-per-poll job if logins become frequent.
  def perform(connection_id)
    connection = Captain::ChatgptConnection.find_by(id: connection_id)
    return unless connection&.pending?

    device = connection.pending_device
    loop do
      return unless waiting?(connection.reload, device)
      return connection.disconnect!(error: error_hash('device_code_expired', 'The ChatGPT device code expired')) if expired?(device)

      code = Captain::Chatgpt::AuthClient.poll_device_token(device_auth_id: device['device_auth_id'], user_code: device['user_code'])
      return complete!(connection, device, code) if code

      sleep [device['interval'].to_i, Captain::Chatgpt::AuthClient::MIN_INTERVAL].max
    end
  rescue Captain::Chatgpt::AuthError, Faraday::Error => e
    fail_login!(connection, device, e)
  rescue ActiveRecord::Encryption::Errors::Configuration
    # Tokens cannot be saved without encryption keys; retrying would fail the same way.
    connection.disconnect!(error: error_hash('encryption_not_configured', 'Active Record encryption keys are not configured on the server'))
  end

  private

  # A newer POST replaces pending_device and a DELETE clears it; either one stops this run.
  def waiting?(connection, device)
    connection.pending? && connection.pending_device['device_auth_id'] == device['device_auth_id']
  end

  def expired?(device)
    Time.zone.parse(device['expires_at']).past?
  end

  def complete!(connection, device, code)
    tokens = Captain::Chatgpt::AuthClient.exchange_code(code: code[:authorization_code], code_verifier: code[:code_verifier])
    connection.with_lock { connection.store_tokens!(tokens) if waiting?(connection, device) }
  end

  def fail_login!(connection, device, error)
    return unless connection && waiting?(connection.reload, device)

    type = error.is_a?(Captain::Chatgpt::AuthError) ? error.type : 'device_login_failed'
    message = error.is_a?(Captain::Chatgpt::AuthError) ? error.message : "ChatGPT login request failed (#{error.class.name})"
    connection.disconnect!(error: error_hash(type, message))
  end

  def error_hash(type, message)
    { type: type, message: message, at: Time.current.iso8601 }
  end
end
