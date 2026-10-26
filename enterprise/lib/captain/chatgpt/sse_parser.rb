# Folds a ChatGPT Codex Responses SSE stream into one assistant message.
# Event names and shapes follow openai/codex codex-rs/codex-api/src/sse/responses.rs (process_responses_event).
class Captain::Chatgpt::SseParser
  RequestError = Captain::Chatgpt::RequestError
  HANDLERS = {
    'response.output_text.delta' => :on_text_delta,
    'response.output_item.added' => :on_item_added,
    'response.function_call_arguments.delta' => :on_arguments_delta,
    'response.output_item.done' => :on_item_done,
    'response.completed' => :on_completed,
    'response.incomplete' => :on_incomplete,
    'response.failed' => :on_failed,
    'error' => :on_error
  }.freeze

  attr_reader :text, :input_tokens, :output_tokens, :cached_tokens, :events_count

  def initialize(&on_text)
    @on_text = on_text
    @buffer = +''
    @text = +''
    @calls = {}
    @events_count = 0
    @completed = false
  end

  def feed(chunk)
    @buffer << chunk.to_s.delete("\r")
    while (index = @buffer.index("\n\n"))
      frame = @buffer.slice!(0, index + 2)
      handle_frame(frame)
    end
  end

  def finish
    handle_frame(@buffer) if @buffer.present?
    @buffer = +''
    raise RequestError.new(type: 'empty_stream', message: 'ChatGPT returned an empty stream') if @events_count.zero?
    raise RequestError.new(type: 'stream_incomplete', message: 'ChatGPT stream ended before response.completed') unless @completed
  end

  def completed?
    @completed
  end

  # Hash of call_id => RubyLLM::ToolCall, in output order; nil when the model called no tools.
  def tool_calls
    calls = @calls.values.to_h do |call|
      [call[:call_id], RubyLLM::ToolCall.new(id: call[:call_id], name: call[:name], arguments: parse_arguments(call))]
    end
    calls.presence
  end

  def to_message(model_id:)
    RubyLLM::Message.new(
      role: :assistant, content: @text, tool_calls: tool_calls, model_id: model_id,
      input_tokens: @input_tokens, output_tokens: @output_tokens, cached_tokens: @cached_tokens
    )
  end

  private

  def handle_frame(frame)
    data = frame.lines.filter_map { |line| line.delete_prefix('data:').strip if line.start_with?('data:') }.join("\n")
    return if data.blank? || data == '[DONE]'

    event = JSON.parse(data)
    @events_count += 1
    handle_event(event)
  rescue JSON::ParserError
    raise RequestError.new(type: 'invalid_stream', message: 'ChatGPT stream sent malformed JSON')
  end

  def handle_event(event)
    handler = HANDLERS[event['type']]
    send(handler, event) if handler
  end

  def on_text_delta(event)
    append_text(event['delta'])
  end

  def on_item_added(event)
    track_call(event['item']) if function_call?(event['item'])
  end

  # Argument deltas reference the item id, not the call id.
  def on_arguments_delta(event)
    call = @calls[event['item_id']] || @calls.values.find { |c| c[:call_id] == event['call_id'] }
    call[:arguments] << event['delta'].to_s if call
  end

  # The done item carries the complete arguments, so it replaces whatever the deltas built.
  def on_item_done(event)
    item = event['item']
    return track_call(item)[:arguments] = item['arguments'].to_s.dup if function_call?(item)

    message_text_fallback(item)
  end

  def on_completed(event)
    usage = event.dig('response', 'usage') || {}
    @input_tokens = usage['input_tokens']
    @output_tokens = usage['output_tokens']
    @cached_tokens = usage.dig('input_tokens_details', 'cached_tokens')
    @completed = true
  end

  def on_incomplete(event)
    reason = RequestError.safe_code(event.dig('response', 'incomplete_details', 'reason')) || 'unknown'
    raise RequestError.new(type: 'response_incomplete', message: "ChatGPT response incomplete: #{reason}")
  end

  def on_failed(event)
    raise_error(event.dig('response', 'error'), 'response_failed')
  end

  def on_error(event)
    raise_error(event['error'] || event, 'stream_error')
  end

  def append_text(delta)
    return if delta.blank?

    @text << delta
    @on_text&.call(delta)
  end

  def function_call?(item)
    item.is_a?(Hash) && item['type'] == 'function_call'
  end

  # function_call items are keyed by item id (call id when the item has none).
  def track_call(item)
    call = (@calls[item['id'] || item['call_id']] ||= { call_id: nil, name: nil, arguments: +'' })
    call[:call_id] = item['call_id'].presence || call[:call_id]
    call[:name] = item['name'].presence || call[:name]
    call[:arguments] = item['arguments'].dup if item['arguments'].present?
    call
  end

  # No text deltas arrived: take the finished message text instead.
  def message_text_fallback(item)
    return unless item.is_a?(Hash) && item['type'] == 'message' && @text.empty?

    Array(item['content']).each { |part| append_text(part['text']) if part['type'] == 'output_text' }
  end

  def raise_error(error, fallback)
    usage_limit = Captain::Chatgpt::UsageLimitError.from_error(error)
    raise usage_limit if usage_limit

    code = error.is_a?(Hash) ? RequestError.safe_code(error['code']) || RequestError.safe_code(error['type']) : nil
    raise RequestError.new(type: fallback, message: ['ChatGPT stream error', code].compact.join(': '))
  end

  def parse_arguments(call)
    return {} if call[:arguments].blank?

    JSON.parse(call[:arguments])
  rescue JSON::ParserError
    raise RequestError.new(type: 'invalid_tool_arguments', message: "ChatGPT sent invalid JSON arguments for tool #{call[:name]}")
  end
end
