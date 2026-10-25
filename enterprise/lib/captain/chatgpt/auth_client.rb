# Codex-style device-code login against auth.openai.com.
# Never log or raise with request/response bodies: they carry tokens.
module Captain::Chatgpt::AuthClient
  include Captain::Chatgpt::Constants

  AuthError = Captain::Chatgpt::AuthError
  AUTH_CLAIMS = 'https://api.openai.com/auth'.freeze
  MIN_INTERVAL = 3
  RATE_LIMIT_RETRIES = 2

  module_function

  def request_device_code
    response = with_rate_limit_retry { post_json('/api/accounts/deviceauth/usercode', client_id: CLIENT_ID) }
    if response.status == 404
      raise AuthError.new(type: 'device_login_disabled',
                          message: 'Device code login is disabled for this ChatGPT account. Enable it in ChatGPT security settings.')
    end
    raise_unless_success!(response, 'device_code_failed')

    body = response.body
    { device_auth_id: body['device_auth_id'], user_code: body['user_code'], interval: [body['interval'].to_i, MIN_INTERVAL].max }
  end

  def poll_device_token(device_auth_id:, user_code:)
    response = post_json('/api/accounts/deviceauth/token', device_auth_id: device_auth_id, user_code: user_code)
    return if [403, 404].include?(response.status)

    raise_unless_success!(response, 'device_poll_failed')
    { authorization_code: response.body['authorization_code'], code_verifier: response.body['code_verifier'] }
  end

  def exchange_code(code:, code_verifier:)
    response = post_form(grant_type: 'authorization_code', code: code, redirect_uri: DEVICE_REDIRECT_URI,
                         client_id: CLIENT_ID, code_verifier: code_verifier)
    raise_unless_success!(response, 'token_exchange_failed')
    token_hash(response.body)
  end

  # 429 is quota; 400/401/403 mean the refresh token is expired, reused or revoked.
  def refresh(refresh_token:)
    response = post_form(grant_type: 'refresh_token', client_id: CLIENT_ID, refresh_token: refresh_token)
    raise AuthError.new(type: 'rate_limited', message: 'ChatGPT token refresh was rate limited') if response.status == 429
    raise AuthError.new(type: 'refresh_rejected', message: error_summary(response)) if [400, 401, 403].include?(response.status)

    raise_unless_success!(response, 'refresh_failed')
    token_hash(response.body)
  rescue Faraday::Error => e
    raise AuthError.new(type: 'refresh_failed', message: "ChatGPT token refresh failed (#{e.class.name})")
  end

  def decode_claims(token)
    payload = JSON.parse(Base64.urlsafe_decode64(token.to_s.split('.')[1].to_s))
    auth = payload[AUTH_CLAIMS] || {}
    { email: payload['email'], exp: payload['exp'], chatgpt_account_id: auth['chatgpt_account_id'], chatgpt_plan_type: auth['chatgpt_plan_type'] }
  rescue ArgumentError, JSON::ParserError
    {}
  end

  def token_hash(body)
    { access_token: body['access_token'], refresh_token: body['refresh_token'], id_token: body['id_token'] }
  end

  def with_rate_limit_retry
    attempt = 0
    loop do
      response = yield
      return response unless response.status == 429 && attempt < RATE_LIMIT_RETRIES

      attempt += 1
      sleep(2**attempt)
    end
  end

  def raise_unless_success!(response, type)
    return if response.success?

    type = 'rate_limited' if response.status == 429
    raise AuthError.new(type: type, message: error_summary(response))
  end

  # HTTP status plus OpenAI's machine error code only; error descriptions are not echoed.
  def error_summary(response)
    body = response.body.is_a?(Hash) ? response.body : {}
    code = body['error'].is_a?(Hash) ? body['error']['code'] : body['error']
    code = nil unless code.is_a?(String) && code.match?(/\A[a-z0-9_.-]{1,64}\z/i)
    ["ChatGPT auth request failed with HTTP #{response.status}", code].compact.join(': ')
  end

  def post_json(path, payload)
    connection.post(path, payload.to_json, 'Content-Type' => 'application/json')
  end

  def post_form(payload)
    connection.post('/oauth/token', URI.encode_www_form(payload), 'Content-Type' => 'application/x-www-form-urlencoded')
  end

  def connection
    Faraday.new(url: ISSUER, headers: { 'User-Agent' => USER_AGENT, 'originator' => ORIGINATOR },
                request: { open_timeout: 10, timeout: 30 }) do |f|
      f.response :json, content_type: /\bjson$/
    end
  end
end
