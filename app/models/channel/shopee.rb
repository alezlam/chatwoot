# == Schema Information
#
# Table name: channel_shopee
#
#  id                       :bigint           not null, primary key
#  access_token             :string           not null
#  expires_at               :datetime         not null
#  refresh_token            :string           not null
#  refresh_token_expires_at :datetime         not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :integer          not null
#  shop_id                  :bigint           not null
#
# Indexes
#
#  index_channel_shopee_on_shop_id  (shop_id) UNIQUE
#
class Channel::Shopee < ApplicationRecord
  include Channelable
  include Reauthorizable
  self.table_name = 'channel_shopee'

  if Chatwoot.encryption_configured?
    encrypts :access_token
    encrypts :refresh_token
  end

  AUTHORIZATION_ERROR_THRESHOLD = 1

  validates :shop_id, uniqueness: true, presence: true
  validates :access_token, :refresh_token, :expires_at, :refresh_token_expires_at, presence: true

  def name
    'Shopee'
  end

  def client
    Shopee::Client.new(shop_id: shop_id, access_token: Shopee::TokenService.new(channel: self).access_token)
  end
end
