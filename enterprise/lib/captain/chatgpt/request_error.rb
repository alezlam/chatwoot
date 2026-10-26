# A failed ChatGPT Responses or models request. Messages carry HTTP status and OpenAI error codes only, never token values.
class Captain::Chatgpt::RequestError < StandardError
  attr_reader :type

  def initialize(type:, message: nil)
    @type = type
    super(message || type)
  end

  # OpenAI machine error codes only; free-text error messages are never echoed.
  def self.safe_code(value)
    value if value.is_a?(String) && value.match?(/\A[a-z0-9_.-]{1,64}\z/i)
  end
end
