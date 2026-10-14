class Api::V1::Accounts::Shopee::AuthorizationsController < Api::V1::Accounts::OauthAuthorizationController
  def create
    redirect = "#{base_url}/shopee/callback?#{{ state: state }.to_query}"
    render json: { success: true, url: Shopee::Client.authorize_url(redirect) }
  end
end
