# Lists the Codex models the connected ChatGPT account may use.
# The catalog is gated by client_version; like Hermes (agent/model_metadata.py) try the newest, then the ungated sentinel.
module Captain::Chatgpt::ModelsClient
  include Captain::Chatgpt::Constants

  CLIENT_VERSIONS = %w[99.0.0 0.0.0].freeze
  HIDDEN = %w[hide hidden].freeze

  module_function

  def list(connection)
    token = connection.fresh_access_token!
    status = nil
    CLIENT_VERSIONS.each do |version|
      response = http.get(MODELS_URL, { client_version: version }, headers(connection, token))
      status = response.status
      next unless response.success?

      ids = model_ids(response.body)
      return ids if ids.any?
    end
    return [] if status.to_i.between?(200, 299)

    raise Captain::Chatgpt::RequestError.new(type: "http_#{status}", message: "ChatGPT models request failed with HTTP #{status}")
  rescue Faraday::Error => e
    raise Captain::Chatgpt::RequestError.new(type: 'request_failed', message: "ChatGPT models request failed (#{e.class.name})")
  end

  # Visible slugs sorted by (priority, slug), as in Hermes hermes_cli/codex_models.py _ranked_slugs.
  def model_ids(body)
    entries = body.is_a?(Hash) ? Array(body['models']) : []
    entries.filter_map { |item| rank(item) }.sort.map(&:last).uniq
  end

  def rank(item)
    return unless item.is_a?(Hash)

    slug = (item['slug'] || item['id']).to_s.strip
    return if slug.empty? || HIDDEN.include?(item['visibility'].to_s.downcase)

    [item['priority'].is_a?(Numeric) ? item['priority'] : 10_000, slug]
  end

  def headers(connection, token)
    { 'Authorization' => "Bearer #{token}", 'ChatGPT-Account-ID' => connection.chatgpt_account_id.to_s,
      'originator' => ORIGINATOR, 'User-Agent' => USER_AGENT }
  end

  # Overridden in checks to stub HTTP.
  def http
    Faraday.new(request: { open_timeout: 10, timeout: 15 }) do |f|
      f.response :json, content_type: /\bjson$/
    end
  end
end
