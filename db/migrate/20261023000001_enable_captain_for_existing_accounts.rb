# Captain is no longer premium-gated on self-hosted installs. Enable it on existing accounts and in the
# stored ACCOUNT_LEVEL_FEATURE_DEFAULTS (ConfigLoader keeps stored values, so the features.yml change alone
# would not reach new signups on an existing install).
class EnableCaptainForExistingAccounts < ActiveRecord::Migration[7.1]
  FEATURES = %w[captain_integration custom_tools].freeze

  def up
    Account.find_in_batches(batch_size: 100) do |accounts|
      accounts.each { |account| account.enable_features!(*FEATURES) }
    end

    enable_default_features
  end

  private

  def enable_default_features
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return if config&.value.blank?

    config.value = config.value.map { |feature| FEATURES.include?(feature['name']) ? feature.merge('enabled' => true) : feature }
    config.save!
    GlobalConfig.clear_cache
  end
end
