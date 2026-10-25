# ruby_llm provider for the ChatGPT Codex backend (streaming Responses API) on the owner's ChatGPT OAuth token.
# The connection comes from params[:chatgpt_connection_id]; it is never sent upstream.
# Never log or raise with request/response bodies or headers: they carry tokens.
class Captain::Chatgpt::Provider < RubyLLM::Provider
  include Captain::Chatgpt::Constants

  RequestError = Captain::Chatgpt::RequestError
  CONNECTION_PARAM_KEYS = [:chatgpt_connection_id, 'chatgpt_connection_id'].freeze
  STREAM_IDLE_TIMEOUT = 60

  class << self
    def slug
      'chatgpt'
    end

    def name
      'ChatGPT'
    end

    def assume_models_exist?
      true
    end

    # Overridden in checks to stub HTTP.
    def http
      Faraday.new(request: { open_timeout: 10, read_timeout: STREAM_IDLE_TIMEOUT, write_timeout: 30 })
    end
  end

  def api_base
    RESPONSES_URL.delete_suffix('/responses')
  end

  # temperature, thinking and tool_prefs land in **_unused: the Codex backend may reject sampling params,
  # and tool_choice/parallel_tool_calls are fixed.
  def complete(messages, tools:, model:, params: {}, headers: {}, schema: nil, **_unused, &) # rubocop:disable Metrics/ParameterLists
    connection = find_connection(params)
    payload = RubyLLM::Utils.deep_merge(render_payload(messages, tools: tools, model: model, schema: schema),
                                        params.except(*CONNECTION_PARAM_KEYS))
    session_id = headers['session-id'] || headers[:'session-id'] || SecureRandom.uuid
    stream_completion(connection, payload, session_id, model_id: model.id, &).tap do
      connection.update!(last_error: {}) if connection.last_error.present?
    end
  rescue Captain::Chatgpt::UsageLimitError => e
    connection&.record_error!(type: 'usage_limit', message: e.message, resets_at: e.resets_at)
    raise
  rescue RequestError => e
    connection&.record_error!(type: e.type, message: e.message)
    raise
  end

  def render_payload(messages, tools:, model:, schema: nil)
    payload = {
      model: model.id,
      instructions: instructions_for(messages),
      input: messages.reject { |m| m.role == :system }.flat_map { |m| input_items(m) },
      tool_choice: 'auto',
      parallel_tool_calls: false,
      store: false,
      stream: true
    }
    payload[:tools] = tools.values.map { |tool| tool_for(tool) } if tools.present?
    payload[:text] = text_format(schema) if schema
    payload
  end

  private

  def instructions_for(messages)
    messages.select { |m| m.role == :system }.map { |m| text_of(m.content) }.join("\n\n")
  end

  def text_format(schema)
    { format: { type: 'json_schema', name: schema[:name], schema: schema[:schema], strict: schema[:strict] } }
  end

  def find_connection(params)
    id = CONNECTION_PARAM_KEYS.filter_map { |key| params[key] }.first
    Captain::ChatgptConnection.find_by(id: id) ||
      raise(Captain::Chatgpt::AuthError.new(type: 'not_connected', message: 'ChatGPT is not connected for this account'))
  end

  # One refresh and one retry on 401.
  def stream_completion(connection, payload, session_id, model_id:, &)
    token = connection.fresh_access_token!
    response, parser = post_stream(connection, token, payload, session_id, &)
    if response.status == 401
      token = force_refresh!(connection, token)
      response, parser = post_stream(connection, token, payload, session_id, &)
    end
    handle_status!(connection, response)
    parser.finish
    parser.to_message(model_id: model_id)
  end

  def post_stream(connection, token, payload, session_id, &block)
    parser = Captain::Chatgpt::SseParser.new { |delta| block&.call(RubyLLM::Chunk.new(role: :assistant, content: delta)) }
    state = { streamed: false, error_body: +'' }
    response = self.class.http.post(RESPONSES_URL) do |req|
      req.headers.merge!(request_headers(connection, token, session_id))
      req.body = payload.to_json
      req.options.on_data = stream_handler(parser, state)
    end
    settle_body(response, parser, state)
    [response, parser]
  rescue Faraday::TimeoutError
    raise RequestError.new(type: 'timeout', message: "ChatGPT sent no events for #{STREAM_IDLE_TIMEOUT}s")
  rescue Faraday::Error => e
    raise RequestError.new(type: 'request_failed', message: "ChatGPT request failed (#{e.class.name})")
  end

  # Success bodies go to the parser as they arrive; error bodies are kept for handle_status!.
  def stream_handler(parser, state)
    proc do |chunk, _size, env|
      state[:streamed] = true
      env&.status.to_i.between?(200, 299) ? parser.feed(chunk) : state[:error_body] << chunk
    end
  end

  def settle_body(response, parser, state)
    if state[:streamed]
      response.env.body = state[:error_body]
    elsif response.success?
      # Adapters that do not stream (Faraday::Adapter::Test) hand back the whole body instead.
      parser.feed(response.body.to_s)
    end
  end

  def request_headers(connection, token, session_id)
    {
      'Authorization' => "Bearer #{token}",
      'ChatGPT-Account-ID' => connection.chatgpt_account_id.to_s,
      'originator' => ORIGINATOR,
      'User-Agent' => USER_AGENT,
      'session-id' => session_id.to_s,
      'Content-Type' => 'application/json',
      'Accept' => 'text/event-stream'
    }
  end

  # Expire the rejected token so fresh_access_token! refreshes under its row lock;
  # if another process already rotated it, the reload picks up the new one instead.
  def force_refresh!(connection, rejected_token)
    connection.reload
    connection.update!(expires_at: nil) if connection.access_token == rejected_token
    connection.fresh_access_token!
  end

  def handle_status!(connection, response)
    return if response.success?

    error = error_hash(response.body)
    usage_limit = Captain::Chatgpt::UsageLimitError.from_error(error) if response.status == 429
    raise usage_limit if usage_limit

    code = RequestError.safe_code(error['code']) || RequestError.safe_code(error['type'])
    message = ["ChatGPT request failed with HTTP #{response.status}", code].compact.join(': ')
    raise RequestError.new(type: "http_#{response.status}", message: message) unless response.status == 401

    # Still rejected after one refresh and retry: the owner must reconnect, so show the reconnect banner.
    connection.disconnect!(error: { type: 'unauthorized', message: message, at: Time.current.iso8601 })
    raise Captain::Chatgpt::AuthError.new(type: 'unauthorized', message: message)
  end

  def error_hash(body)
    parsed = body.is_a?(String) ? JSON.parse(body) : body
    parsed.is_a?(Hash) && parsed['error'].is_a?(Hash) ? parsed['error'] : {}
  rescue JSON::ParserError
    {}
  end

  def input_items(message)
    case message.role
    when :tool
      [{ type: 'function_call_output', call_id: message.tool_call_id, output: text_of(message.content) }]
    when :assistant
      text = text_of(message.content)
      items = text.present? ? [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: text }] }] : []
      items + (message.tool_calls || {}).values.map do |call|
        { type: 'function_call', call_id: call.id, name: call.name, arguments: JSON.generate(call.arguments || {}) }
      end
    else
      [{ type: 'message', role: 'user', content: user_content(message.content) }]
    end
  end

  def user_content(content)
    text = text_of(content)
    parts = text.present? ? [{ type: 'input_text', text: text }] : []
    return parts unless content.is_a?(RubyLLM::Content)

    parts + content.attachments.select(&:image?).map do |image|
      { type: 'input_image', image_url: image.url? ? image.source.to_s : image.for_llm }
    end
  end

  def text_of(content)
    case content
    when RubyLLM::Content::Raw then content.value.is_a?(String) ? content.value : content.value.to_json
    when RubyLLM::Content then content.text.to_s
    when Hash, Array then content.to_json
    else content.to_s
    end
  end

  # Responses function tools are flat. Responses defaults strict to true, which demands every property in
  # `required`; send false like codex and Hermes, and drop ruby_llm's `strict` key from inside the JSON schema.
  def tool_for(tool)
    parameters = RubyLLM::Providers::OpenAI::Tools.parameters_schema_for(tool).deep_dup
    parameters = parameters.except('strict', :strict) if parameters.is_a?(Hash)
    { type: 'function', name: tool.name, description: tool.description, strict: false, parameters: parameters }
  end
end
