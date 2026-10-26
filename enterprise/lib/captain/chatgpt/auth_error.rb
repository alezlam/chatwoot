# Messages carry HTTP status and OpenAI error codes only, never token values.
class Captain::Chatgpt::AuthError < StandardError
  attr_reader :type, :resets_at

  def initialize(type:, message: nil, resets_at: nil)
    @type = type
    @resets_at = resets_at
    super(message || type)
  end
end
