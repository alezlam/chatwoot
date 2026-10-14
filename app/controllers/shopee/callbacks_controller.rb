class Shopee::CallbacksController < ApplicationController
  def show
    return head :unauthorized if account.blank?

    # A Main Account login comes back with main_account_id instead of a shop.
    raise 'Shopee did not return a shop. Authorize a single shop, not a main account.' if params[:shop_id].blank? || params[:code].blank?

    inbox = connect_shop
    redirect_to app_shopee_inbox_agents_url(account_id: account.id, inbox_id: inbox.id)
  rescue StandardError => e
    raise if account.blank?

    handle_error(e)
  end

  private

  def handle_error(error)
    Rails.logger.error("Shopee channel creation error: #{error.message}")
    ChatwootExceptionTracker.new(error).capture_exception
    redirect_to app_new_shopee_inbox_url(account_id: account.id, error_message: error.message)
  end

  def account
    @account ||= GlobalID::Locator.locate_signed(params[:state], for: 'default')
  end

  def connect_shop
    shop_id = params[:shop_id].to_i
    tokens = Shopee::TokenService.token_attributes(Shopee::Client.fetch_token(params[:code], shop_id))
    channel = account.shopee_channels.find_by(shop_id: shop_id)

    if channel
      channel.update!(tokens)
    else
      channel = create_channel_with_inbox(shop_id, tokens)
    end
    channel.reauthorized!
    channel.inbox
  end

  def create_channel_with_inbox(shop_id, tokens)
    shop_name = Shopee::Client.new(shop_id: shop_id, access_token: tokens[:access_token]).shop_info['shop_name']

    ActiveRecord::Base.transaction do
      channel = Channel::Shopee.create!(account: account, shop_id: shop_id, **tokens)
      account.inboxes.create!(account: account, channel: channel, name: shop_name.presence || "Shopee #{shop_id}")
      channel
    end
  end
end
