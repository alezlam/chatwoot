# Shopee Open Platform v2. Every call is signed with HMAC-SHA256 of the partner key:
#   partner-level (auth): partner_id + path + timestamp
#   shop-level:           partner_id + path + timestamp + access_token + shop_id
class Shopee::Client
  HOSTS = {
    'live' => 'https://partner.shopeemobile.com',
    'sandbox' => 'https://openplatform.sandbox.test-stable.shopee.sg'
  }.freeze
  AUTH_ERRORS = %w[error_auth error_token_expired error_invalid_access_token].freeze

  class Error < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super("[#{code}] #{message}")
    end

    def auth_error?
      AUTH_ERRORS.include?(code)
    end
  end

  class << self
    def configured?
      partner_id.positive? && partner_key.present?
    end

    # Read from ENV, not GlobalConfigService: that copies a value into the database on first read,
    # so a later change to the Railway variable would never take effect.
    def partner_id
      ENV.fetch('SHOPEE_PARTNER_ID', 0).to_i
    end

    def partner_key
      ENV.fetch('SHOPEE_PARTNER_KEY', '').strip
    end

    def push_partner_key
      ENV.fetch('SHOPEE_PUSH_PARTNER_KEY', '').strip
    end

    def sign(base)
      OpenSSL::HMAC.hexdigest('SHA256', partner_key, base)
    end

    # The page a seller visits to authorize the app to their shop; Shopee redirects back with code + shop_id.
    def authorize_url(redirect)
      path = '/api/v2/shop/auth_partner'
      ts = Time.now.to_i
      query = { partner_id: partner_id, timestamp: ts, sign: sign("#{partner_id}#{path}#{ts}"), redirect: redirect }
      "#{host}#{path}?#{query.to_query}"
    end

    def fetch_token(code, shop_id)
      post_public('/api/v2/auth/token/get', code: code, shop_id: shop_id.to_i, partner_id: partner_id)
    end

    def refresh_token(refresh_token, shop_id)
      post_public('/api/v2/auth/access_token/get', refresh_token: refresh_token, shop_id: shop_id.to_i, partner_id: partner_id)
    end

    def host
      HOSTS.fetch(ENV.fetch('SHOPEE_ENV', 'live'))
    end

    def parse(response)
      json = response.parsed_response
      json = JSON.parse(json) if json.is_a?(String)
      raise Error.new(json['error'], json['message']) if json['error'].present?

      # Most endpoints wrap the payload in `response`; auth and get_shop_info return it at the top level.
      json['response'] || json
    end

    private

    def post_public(path, body)
      ts = Time.now.to_i
      query = { partner_id: partner_id, timestamp: ts, sign: sign("#{partner_id}#{path}#{ts}") }
      parse(HTTParty.post("#{host}#{path}", query: query, body: body.to_json, headers: { 'Content-Type' => 'application/json' }))
    end
  end

  pattr_initialize [:shop_id!, :access_token!]

  def shop_info
    get('/api/v2/shop/get_shop_info')
  end

  # Buyer of the conversation: to_id, to_name, to_avatar.
  def conversation(conversation_id)
    get('/api/v2/sellerchat/get_one_conversation', conversation_id: conversation_id)
  end

  # Latest page of the conversation, newest first.
  def messages(conversation_id)
    get('/api/v2/sellerchat/get_message', conversation_id: conversation_id, page_size: 50)['messages'] || []
  end

  # Shopee addresses a reply to the buyer's user id, not the conversation.
  def send_text(to_id, text)
    post('/api/v2/sellerchat/send_message', to_id: to_id.to_i, message_type: 'text', content: { text: text })
  end

  private

  def get(path, params = {})
    self.class.parse(HTTParty.get("#{self.class.host}#{path}", query: signed_query(path).merge(params)))
  end

  def post(path, body)
    self.class.parse(
      HTTParty.post("#{self.class.host}#{path}", query: signed_query(path), body: body.to_json, headers: { 'Content-Type' => 'application/json' })
    )
  end

  def signed_query(path)
    partner_id = self.class.partner_id
    ts = Time.now.to_i
    sign = self.class.sign("#{partner_id}#{path}#{ts}#{access_token}#{shop_id}")
    { partner_id: partner_id, timestamp: ts, access_token: access_token, shop_id: shop_id, sign: sign }
  end
end
