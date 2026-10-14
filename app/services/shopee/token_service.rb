# Shopee access tokens last 4 hours; refresh tokens 30 days, and every refresh issues a new one.
class Shopee::TokenService
  REFRESH_TOKEN_TTL = 30.days

  pattr_initialize [:channel!]

  def access_token
    return channel.access_token if 5.minutes.from_now < channel.expires_at
    return refresh_access_token if Time.current < channel.refresh_token_expires_at

    channel.prompt_reauthorization! unless channel.reauthorization_required?
    channel.access_token
  end

  def self.token_attributes(token)
    {
      access_token: token['access_token'],
      refresh_token: token['refresh_token'],
      expires_at: Time.current + token['expire_in'].to_i.seconds,
      refresh_token_expires_at: Time.current + REFRESH_TOKEN_TTL
    }
  end

  private

  def refresh_access_token
    lock_manager = Redis::LockManager.new
    lock_key = format(::Redis::Alfred::SHOPEE_REFRESH_TOKEN_MUTEX, channel_id: channel.id)
    # Another process is refreshing; the current token is still valid for a few minutes.
    return channel.access_token unless lock_manager.lock(lock_key, 30.seconds)

    begin
      channel.update!(self.class.token_attributes(Shopee::Client.refresh_token(channel.refresh_token, channel.shop_id)))
      channel.access_token
    rescue Shopee::Client::Error => e
      channel.authorization_error! if e.auth_error?
      raise
    ensure
      lock_manager.unlock(lock_key)
    end
  end
end
