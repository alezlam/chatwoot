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
    total = corpus.size
    doc_freq = query_tokens.index_with { |token| corpus.count { |e| e[:tokens].include?(token) } }
    candidates = corpus.reject { |e| e[:kind] == :product && exclude_product_ids.include?(e[:record].id) }

    candidates.filter_map { |e| score_entry(e, query_tokens, doc_freq, total) }
  end

  def score_entry(entry, query_tokens, doc_freq, total)
    base = query_tokens.select { |token| entry[:tokens].include?(token) }.sum { |token| Math.log(total.to_f / doc_freq[token]) }
    entry.merge(score: base * trust_factor(entry[:record])).except(:tokens) if base.positive?
  end

  def trust_factor(record)
    confirmed = record.confirmed ? CONFIRMED_FACTOR : 1
    confirmed * (1 + [MAX_HITS_BOOST, HITS_BOOST_STEP * Math.log(1 + record.hits)].min)
  end

  def select_entries(scored, top_k, char_limit)
    return nil if scored.empty?

    sorted = scored.sort_by { |e| -e[:score] }
    threshold = sorted.first[:score] * MIN_RELATIVE_SCORE
    kept = []
    used = 0
    sorted.first(top_k).each do |e|
      break if e[:score] < threshold || used + e[:markdown].length > char_limit

      kept << e
      used += e[:markdown].length
    end
    kept.empty? ? nil : Result.new(entries: kept)
  end
end
