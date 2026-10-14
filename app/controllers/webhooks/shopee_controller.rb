# Shopee push mechanism. Signature = HMAC-SHA256(push partner key, "<push url>|<raw body>") in the Authorization header.
# The push partner key is its own key in the Shopee console, not the API partner key.
# Push codes: 0 console verification, 1 shop authorization, 3 order status, 10 webchat message. Only chat is handled.
class Webhooks::ShopeeController < ActionController::API
  VERIFICATION_PUSH = 0
  WEBCHAT_PUSH = 10

  before_action :verify_signature!, unless: :verification_push?

  def events
    # Delay so the message_id of a reply sent from Chatwoot is saved before its echo syncs.
    ::Webhooks::ShopeeEventsJob.set(wait: 3.seconds).perform_later(payload) if payload['code'] == WEBCHAT_PUSH

    head :ok
  end

  private

  def payload
    @payload ||= JSON.parse(request.raw_post)
  end

  # The console's "verify callback URL" ping carries no shop data and triggers nothing.
  def verification_push?
    payload['code'] == VERIFICATION_PUSH
  end

  def verify_signature!
    key = Shopee::Client.push_partner_key
    return head :unauthorized if key.blank?

    # Shopee signs the public URL it posted to, not the internal host the request reached.
    url = "#{ENV.fetch('FRONTEND_URL')}/webhooks/shopee"
    expected = OpenSSL::HMAC.hexdigest('SHA256', key, "#{url}|#{request.raw_post}")
    return if ActiveSupport::SecurityUtils.secure_compare(expected, request.headers['Authorization'].to_s)

    Rails.logger.warn("Shopee push signature mismatch: signed_url=#{url} header_present=#{request.headers['Authorization'].present?}")
    head :unauthorized
  end
end
