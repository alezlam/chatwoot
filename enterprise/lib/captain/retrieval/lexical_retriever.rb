# ponytail: the corpus is loaded and tokenized per call. Fine for a shop (up to a few thousand entries);
# beyond that, prefilter with a pg_trgm / tsvector query and score only the candidates.
class Captain::Retrieval::LexicalRetriever
  TOP_K = 5
  CHAR_LIMIT = 4000
  MIN_RELATIVE_SCORE = 0.3
  CONFIRMED_FACTOR = 1.5
  MAX_HITS_BOOST = 0.3
  HITS_BOOST_STEP = 0.1

  Result = Data.define(:entries) do
    def product_ids = ids_for(:product)
    def faq_ids = ids_for(:faq)
    def to_markdown = entries.map { |entry| entry[:markdown] }.join("\n")

    private

    def ids_for(kind) = entries.select { |entry| entry[:kind] == kind }.map { |entry| entry[:record].id }
  end

  def self.cache_key(assistant) = "captain:retrieval:common:#{assistant.id}"

  def self.common_tokens(assistant)
    Rails.cache.read(cache_key(assistant)) || Set.new
  end

  def initialize(assistant:, kinds: %i[products faqs])
    @assistant = assistant
    @kinds = kinds
  end

  def search(query, top_k: TOP_K, char_limit: CHAR_LIMIT, exclude_product_ids: [])
    query_tokens = Captain::Retrieval::Tokenizer.tokens(query, common: self.class.common_tokens(@assistant)).uniq
    return nil if query_tokens.empty?

    corpus = build_corpus
    return nil if corpus.empty?

    scored = score(corpus, query_tokens, exclude_product_ids)
    select_entries(scored, top_k, char_limit)
  end

  private

  def build_corpus
    corpus = []
    @assistant.products.enabled.find_each { |product| corpus << product_entry(product) } if @kinds.include?(:products)
    @assistant.responses.find_each { |response| corpus << faq_entry(response) } if @kinds.include?(:faqs)
    corpus
  end

  def product_entry(product)
    body = [product.description, product.context, product.prompt].compact_blank.join("\n")
    entry(product, :product, product.name, body)
  end

  def faq_entry(response)
    entry(response, :faq, response.question, response.answer)
  end

  def entry(record, kind, heading, body)
    markdown = "## #{heading}\n#{body}\nconfirmed: #{record.confirmed}\nhits: #{record.hits}\n"
    { record: record, kind: kind, markdown: markdown, tokens: Captain::Retrieval::Tokenizer.tokens("#{heading}\n#{body}").to_set }
  end

  def score(corpus, query_tokens, exclude_product_ids)
    candidates = corpus.reject { |e| e[:kind] == :product && exclude_product_ids.include?(e[:record].id) }
    matched = candidates.index_with { |e| query_tokens.select { |token| e[:tokens].include?(token) } }
    bases = base_scores(corpus, matched)

    candidates.filter_map do |e|
      e.merge(score: bases[e] * trust_factor(e[:record])).except(:tokens) if bases[e].positive?
    end
  end

  def base_scores(corpus, matched)
    doc_freq = matched.values.flatten.uniq.index_with { |token| corpus.count { |e| e[:tokens].include?(token) } }
    bases = matched.transform_values { |tokens| tokens.sum { |token| Math.log(corpus.size.to_f / doc_freq[token]) } }
    # Degenerate IDF (one-entry corpus, or every matching token in every entry) scores 0: fall back to matched-token count.
    bases.values.any?(&:positive?) ? bases : matched.transform_values(&:size)
  end

  def trust_factor(record)
    confirmed = record.confirmed ? CONFIRMED_FACTOR : 1
    confirmed * (1 + [MAX_HITS_BOOST, HITS_BOOST_STEP * Math.log(1 + record.hits)].min)
  end

  def select_entries(scored, top_k, char_limit)
    return nil if scored.empty?

    sorted = scored.sort_by { |e| -e[:score] }
    threshold = sorted.first[:score] * MIN_RELATIVE_SCORE
    kept = fit_to_limit(sorted.first(top_k).select { |e| e[:score] >= threshold }, char_limit)
    kept.empty? ? nil : Result.new(entries: kept)
  end

  # Stops before the cumulative markdown passes char_limit. The best entry alone may exceed it: keep it truncated, never return nothing.
  def fit_to_limit(entries, char_limit)
    used = 0
    kept = entries.take_while { |e| (used += e[:markdown].length) <= char_limit }
    return kept if kept.any? || entries.empty?

    [entries.first.merge(markdown: entries.first[:markdown][0, char_limit])]
  end
end
