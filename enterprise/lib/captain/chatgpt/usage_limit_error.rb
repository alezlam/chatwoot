# The ChatGPT plan's usage limit is reached until resets_at. When the server does not say when, resets_at defaults to
# DEFAULT_BACKOFF from now, so rate_limited? still pauses draft runs and the notice shows.
class Captain::Chatgpt::UsageLimitError < StandardError
  TYPES = %w[usage_limit_reached workspace_member_usage_limit_reached].freeze
  DEFAULT_BACKOFF = 15.minutes

  attr_reader :type, :resets_at

  # From a Responses error object ({ "type": "usage_limit_reached", "resets_at": <unix seconds> }); nil for any other error.
  def self.from_error(error)
    return unless error.is_a?(Hash) && TYPES.include?(error['type'])

    new(type: error['type'], resets_at: error['resets_at'].is_a?(Numeric) ? Time.zone.at(error['resets_at']) : nil)
  end

  def initialize(type:, resets_at: nil)
    @type = type
    @resets_at = resets_at || DEFAULT_BACKOFF.from_now
    super("ChatGPT usage limit reached until #{@resets_at.iso8601}")
  end
end
