class Captain::Tools::ProductLookupTool < Captain::Tools::BasePublicTool
  NO_RESULTS = 'No matching products found.'.freeze

  description 'Search the product catalog to find the products the customer is asking about'
  param :query, type: 'string', desc: 'The product name, type or question to search the product catalog for'

  def perform(tool_context, query:)
    log_tool_usage('searching', { query: query })
    result = Captain::Retrieval::LexicalRetriever.new(assistant: @assistant, kinds: %i[products]).search(query)

    if result.nil?
      log_tool_usage('no_results', { query: query })
      return NO_RESULTS
    end

    ids = tool_context.state[:retrieved_product_ids] ||= []
    ids.concat(result.product_ids - ids)
    log_tool_usage('found_results', { query: query, count: result.entries.size })
    result.entries.map { |entry| format_product(entry[:record]) }.join("\n")
  end

  private

  def safe_to_run_after_new_customer_message?
    true
  end

  def format_product(product)
    <<~PRODUCT
      Product result:
      Name: #{product.name}
      Shopee item id: #{product.shopee_item_id}
      Description: #{product.description}
      How to answer about this product: #{product.prompt}
      Context: #{product.context}
    PRODUCT
  end
end
