# Measures the lexical retriever (hit@TOP_K, MRR) on labelled buyer queries. Read-only: it never writes to the DB.
#   rake 'captain:retrieval_eval[ASSISTANT_ID]' [LABELS=path.yml] [WITH_AGENT=1]
# Queries come from card conversations (product card -> the buyer's text messages) and an optional YAML
# of [{ query:, expected_type: product|faq, expected_id: }]. WITH_AGENT=1 also runs the draft agent with
# injection off and scores the ids its tools returned, in call order.
# Rake files load before the app constants, hence a top-level class with no Captain:: reference at class level.
class CaptainRetrievalEval
  CARD_TEXT = /\A(Product|Order): \S+\z/
  def top_k = Captain::Retrieval::LexicalRetriever::TOP_K

  Query = Struct.new(:text, :kind, :id, :conversation, keyword_init: true)

  def initialize(assistant, labels_path:, with_agent:)
    @assistant = assistant
    @labels_path = labels_path
    @with_agent = with_agent
  end

  def perform
    queries = card_queries + yaml_queries
    return puts('No labelled queries found.') if queries.empty?

    rows = { 'retriever' => queries.map { |q| [q, retriever_ranking(q)] } }
    rows['agent (no injection)'] = queries.map { |q| [q, agent_ranking(q)] } if @with_agent && agent_ready?
    print_report(rows)
  end

  private

  def agent_ready?
    return true if @assistant.account.captain_chatgpt_connection&.connected?

    puts 'Skipping agent baseline: no connected ChatGPT connection on this account.'
    false
  end

  def card_queries
    enabled = @assistant.products.enabled.index_by(&:shopee_item_id)
    conversation_ids = Message.where(inbox_id: @assistant.captain_inboxes.select(:inbox_id)).incoming
                              .where("#{Captain::Products::MatchService::SHOPEE_ITEM_ID_SQL} IS NOT NULL OR messages.content ~ ?",
                                     Captain::Products::MatchService::CARD_CONTENT_SQL_PATTERN)
                              .reorder(nil).distinct.pluck(:conversation_id)
    Conversation.where(id: conversation_ids).find_each.flat_map { |conversation| conversation_queries(conversation, enabled) }
  end

  def conversation_queries(conversation, enabled)
    messages = conversation.messages.incoming.where(private: false).order(:id).to_a
    product = messages.reverse_each.filter_map { |m| enabled[card_item_id(m)] }.first
    return [] if product.nil?

    messages.reject { |m| m.content.blank? || m.content.match?(CARD_TEXT) }
            .map { |m| Query.new(text: m.content, kind: :product, id: product.id, conversation: conversation) }
  end

  def card_item_id(message)
    message.content_attributes['shopee_item_id'].presence || message.content.to_s[Captain::Products::MatchService::CARD_CONTENT_REGEX, 1]
  end

  def yaml_queries
    return [] if @labels_path.blank?

    YAML.safe_load_file(@labels_path, permitted_classes: [Symbol]).map do |row|
      row = row.symbolize_keys
      Query.new(text: row[:query], kind: row[:expected_type].to_sym, id: row[:expected_id].to_i, conversation: nil)
    end
  end

  def retriever_ranking(query)
    result = Captain::Retrieval::LexicalRetriever.new(assistant: @assistant).search(query.text, top_k: top_k)
    result ? result.entries.map { |entry| [entry[:kind], entry[:record].id] } : []
  end

  def agent_ranking(query)
    conversation = query.conversation || @assistant.inboxes.first&.conversations&.first
    return [] if conversation.nil?

    run_options = Captain::Assistant::AgentRunnerService::RunOptions.new(
      source: Captain::Assistant::AgentRunnerService::DRAFT_SOURCE, runtime_configuration: { draft: true }
    )
    runner = Captain::Assistant::AgentRunnerService.new(assistant: @assistant, conversation: conversation, run_options: run_options)
    runner.generate_response(message_history: [{ role: 'user', content: query.text }])
    ids = runner.retrieved_ids
    ids[:product_ids].map { |id| [:product, id] } + ids[:faq_ids].map { |id| [:faq, id] }
  end

  def print_report(rows)
    puts table_row('variant', 'n', "hit@#{top_k}", 'MRR')
    rows.each do |variant, scored|
      ranks = scored.map { |query, ranking| rank_of(query, ranking) }
      hit = ranks.count(&:positive?).fdiv(ranks.size)
      mrr = ranks.sum { |rank| rank.positive? ? 1.0 / rank : 0.0 }.fdiv(ranks.size)
      puts table_row(variant, ranks.size, hit.round(3).to_s.ljust(5, '0'), mrr.round(3).to_s.ljust(5, '0'))
    end
    print_misses(rows)
  end

  def table_row(variant, count, hit, mrr) = "#{variant.to_s.ljust(22)} | #{count.to_s.rjust(5)} | #{hit.to_s.rjust(6)} | #{mrr.to_s.rjust(6)}"

  # 1-based rank of the expected (kind, id) within the top TOP_K, 0 when absent.
  def rank_of(query, ranking)
    index = ranking.first(top_k).index([query.kind, query.id])
    index ? index + 1 : 0
  end

  def print_misses(rows)
    rows.each do |variant, scored|
      misses = scored.select { |query, ranking| rank_of(query, ranking).zero? }.first(10)
      next if misses.empty?

      puts "\nWorst misses (#{variant}):"
      misses.each { |query, ranking| puts "#{query.text.to_s.squish.truncate(80)} → #{describe(query)} | got #{ranking.map { |k, i| "#{k}##{i}" }}" }
    end
  end

  def describe(query)
    record = query.kind == :faq ? @assistant.responses.find_by(id: query.id) : @assistant.products.find_by(id: query.id)
    "#{query.kind}##{query.id} #{(record.try(:name) || record.try(:question)).to_s.truncate(40)}"
  end
end

namespace :captain do
  desc 'Retrieval eval: rake "captain:retrieval_eval[ASSISTANT_ID]" LABELS=path.yml WITH_AGENT=1'
  task :retrieval_eval, [:assistant_id] => :environment do |_task, args|
    assistant = Captain::Assistant.find(args[:assistant_id])
    CaptainRetrievalEval.new(assistant, labels_path: ENV.fetch('LABELS', nil), with_agent: ENV['WITH_AGENT'] == '1').perform
  end
end
