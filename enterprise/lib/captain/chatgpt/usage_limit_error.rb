# The ChatGPT plan's usage limit is reached until resets_at (a Time, or nil when the server did not say).
class Captain::Chatgpt::UsageLimitError < StandardError
  TYPES = %w[usage_limit_reached workspace_member_usage_limit_reached].freeze

  attr_reader :type, :resets_at

  # From a Responses error object ({ "type": "usage_limit_reached", "resets_at": <unix seconds> }); nil for any other error.
  def self.from_error(error)
    return unless error.is_a?(Hash) && TYPES.include?(error['type'])

    new(type: error['type'], resets_at: error['resets_at'].is_a?(Numeric) ? Time.zone.at(error['resets_at']) : nil)
  end

  def initialize(type:, resets_at: nil)
    @type = type
    @resets_at = resets_at
    super(['ChatGPT usage limit reached', resets_at && "until #{resets_at.iso8601}"].compact.join(' '))
  end
end
