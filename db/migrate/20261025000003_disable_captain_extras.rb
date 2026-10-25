# ponytail: Captain extras need an OpenAI API key; they stay off until the ChatGPT provider covers them.
class DisableCaptainExtras < ActiveRecord::Migration[7.1]
  def up
    Account.find_in_batches(batch_size: 100) do |accounts|
      accounts.each { |account| account.disable_features!('captain_tasks') }
    end

    disable_default_feature
    Captain::Assistant.update_all("config = COALESCE(config, '{}'::jsonb) || '{\"feature_faq\": false, \"feature_memory\": false}'::jsonb") # rubocop:disable Rails/SkipsModelValidations
  end

  private

  def disable_default_feature
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return if config&.value.blank?

    config.value = config.value.map { |feature| feature['name'] == 'captain_tasks' ? feature.merge('enabled' => false) : feature }
    config.save!
    GlobalConfig.clear_cache
  end
end
