# Shopee push mechanism. Signature = HMAC-SHA256(push partner key, "<push url>|<raw body>") in the Authorization header.
# The push partner key is its own key in the Shopee console, not the API partner key.
# Push codes: 1 shop authorization, 3 order status, 10 webchat message, 12 item promotion. Only chat is handled.
class Webhooks::ShopeeController < ActionController::API
  WEBCHAT_PUSH = 10

  before_action :verify_signature!

  def events
    payload = JSON.parse(request.raw_post)
    # Delay so the message_id of a reply sent from Chatwoot is saved before its echo syncs.
    ::Webhooks::ShopeeEventsJob.set(wait: 3.seconds).perform_later(payload) if payload['code'] == WEBCHAT_PUSH

    head :ok
  end

  private

  def verify_signature!
    key = GlobalConfigService.load('SHOPEE_PUSH_PARTNER_KEY', '').to_s.strip
    return head :unauthorized if key.blank?

    # Shopee signs the public URL it posted to, not the internal host the request reached.
    url = "#{ENV.fetch('FRONTEND_URL')}/webhooks/shopee"
    expected = OpenSSL::HMAC.hexdigest('SHA256', key, "#{url}|#{request.raw_post}")
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(expected, request.headers['Authorization'].to_s)
  end
end
