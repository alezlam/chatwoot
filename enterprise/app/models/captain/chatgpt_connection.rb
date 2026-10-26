# == Schema Information
#
# Table name: captain_chatgpt_connections
#
#  id                 :bigint           not null, primary key
#  access_token       :text
#  email              :string
#  expires_at         :datetime
#  id_token           :text
#  last_error         :jsonb            not null
#  model              :string
#  pending_device     :jsonb            not null
#  plan_type          :string
#  refresh_token      :text
#  status             :integer          default("disconnected"), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  chatgpt_account_id :string
#
# Indexes
#
#  index_captain_chatgpt_connections_on_account_id  (account_id) UNIQUE
#
class Captain::ChatgptConnection < ApplicationRecord
  self.table_name = 'captain_chatgpt_connections'

  REFRESH_MARGIN = 5.minutes
  DEVICE_CODE_TTL = 15.minutes

  belongs_to :account

  enum status: { disconnected: 0, pending: 1, connected: 2 }

  encrypts :access_token, :refresh_token, :id_token

  validates :account_id, uniqueness: true

  def fresh_access_token!
    raise_not_connected! unless connected?
    return access_token unless refresh_due?

    error = nil
    # with_lock re-reads the row (SELECT ... FOR UPDATE), so a second caller sees the rotated token
    # and skips the refresh. The error is raised after the lock so the status update is not rolled back.
    with_lock do
      raise_not_connected! unless connected?
      next unless refresh_due?

      begin
        store_tokens!(Captain::Chatgpt::AuthClient.refresh(refresh_token: refresh_token))
      rescue Captain::Chatgpt::AuthError => e
        handle_refresh_error(e)
        error = e
      end
    end
    raise error if error

    access_token
  end

  def start_device_login!
    device = Captain::Chatgpt::AuthClient.request_device_code
    update!(clear_tokens_attributes.merge(status: :pending, last_error: {},
                                          pending_device: device.merge(expires_at: DEVICE_CODE_TTL.from_now.iso8601)))
  end

  def store_tokens!(tokens)
    new_id_token = tokens[:id_token].presence || id_token
    access_claims = Captain::Chatgpt::AuthClient.decode_claims(tokens[:access_token])
    claims = access_claims.merge(Captain::Chatgpt::AuthClient.decode_claims(new_id_token).compact)
    update!(
      status: :connected, access_token: tokens[:access_token], refresh_token: tokens[:refresh_token].presence || refresh_token,
      id_token: new_id_token, expires_at: access_claims[:exp] && Time.zone.at(access_claims[:exp]),
      email: claims[:email], chatgpt_account_id: claims[:chatgpt_account_id], plan_type: claims[:chatgpt_plan_type],
      pending_device: {}, last_error: kept_usage_limit_error
    )
  end

  # The model for a draft run: the owner's pick, else the first one ChatGPT lists (saved so the UI shows it).
  # Returns nil after recording last_error when there is none to use.
  def draft_model!
    return model if model.present?

    first_model = Captain::Chatgpt::ModelsClient.list(self).first
    if first_model.blank?
      record_error!(type: 'no_models', message: 'ChatGPT listed no models for this account')
      return
    end

    update!(model: first_model)
    first_model
  rescue Captain::Chatgpt::RequestError => e
    record_error!(type: e.type, message: e.message)
    nil
  end

  def disconnect!(error: {})
    update!(clear_tokens_attributes.merge(status: :disconnected, pending_device: {}, last_error: error))
  end

  def record_error!(type:, message:, resets_at: nil)
    update!(last_error: { type: type, message: message, resets_at: resets_at&.iso8601, at: Time.current.iso8601 }.compact)
  end

  def rate_limited?
    resets_at = last_error['resets_at'].presence
    resets_at.present? && Time.zone.parse(resets_at).future?
  end

  def as_status_json
    {
      status: status,
      email: email,
      plan_type: plan_type,
      model: model,
      user_code: pending? ? pending_device['user_code'] : nil,
      verification_url: pending? ? Captain::Chatgpt::Constants::VERIFICATION_URL : nil,
      last_error: last_error
    }
  end

  private

  # A token refresh must not erase the usage-limit notice before the limit resets.
  def kept_usage_limit_error
    last_error['type'] == 'usage_limit' && rate_limited? ? last_error : {}
  end

  def refresh_due?
    expires_at.nil? || expires_at < REFRESH_MARGIN.from_now
  end

  def handle_refresh_error(error)
    if error.type == 'refresh_rejected'
      disconnect!(error: { type: error.type, message: error.message, at: Time.current.iso8601 })
    else
      record_error!(type: error.type, message: error.message, resets_at: error.resets_at)
    end
  end

  def raise_not_connected!
    raise Captain::Chatgpt::AuthError.new(type: 'not_connected', message: 'ChatGPT is not connected for this account')
  end

  def clear_tokens_attributes
    { access_token: nil, refresh_token: nil, id_token: nil, expires_at: nil, email: nil, chatgpt_account_id: nil, plan_type: nil }
  end
end
