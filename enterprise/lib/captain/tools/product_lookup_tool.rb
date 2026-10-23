class Captain::Tools::ProductLookupTool < Captain::Tools::BasePublicTool
  NO_RESULTS = 'No matching products found.'.freeze

  description 'Search the product catalog using semantic similarity to find the products the customer is asking about'
  param :query, type: 'string', desc: 'The product name, type or question to search the product catalog for'

  def perform(_tool_context, query:)
    log_tool_usage('searching', { query: query })
    # A blank query embeds to [], which nearest_neighbors rejects.
    products = query.present? ? Captain::Product.search(query, assistant: @assistant).to_a : []

    if products.empty?
      log_tool_usage('no_results', { query: query })
      return NO_RESULTS
    end

    log_tool_usage('found_results', { query: query, count: products.size })
    products.map { |product| format_product(product) }.join("\n")
  end

  private

  def safe_to_run_after_new_customer_message?
    true
  end

  def format_product(product)
    <<~PRODUCT
      Product result:
      Name: #{product.name}
      Description: #{product.description}
      How to answer about this product: #{product.prompt}
      Context: #{product.context}
    PRODUCT
  end
end
