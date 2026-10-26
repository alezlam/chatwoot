# Measures the lexical retriever (hit@TOP_K, MRR) on labelled buyer queries. The retriever pass is read-only.
# WITH_AGENT=1 runs the agent through the ChatGPT connection, which may refresh its tokens, record last_error
# and save the first listed model when none is picked (as a draft run does).
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
    agent_errors = add_agent_row(rows, queries) if @with_agent && agent_ready?
    print_report(rows)
    puts "agent errors: #{agent_errors} (excluded from the agent row)" if agent_errors
  end

  # Adds the agent row from the runs that succeeded; returns the number of runs that errored.
  def add_agent_row(rows, queries)
    runs = queries.map { |q| [q, agent_ranking(q)] }
    rows['agent (no injection)'], errored = runs.partition { |_, ranking| ranking }
    errored.size
  end

  private

  def agent_ready?
    connection = @assistant.account.captain_chatgpt_connection
    return skip_agent('no connected ChatGPT connection on this account') unless connection&.connected?
    # The runner reads connection.model; draft_model! picks the first listed one when the owner chose none.
    return skip_agent("no model (#{connection.last_error['type']})") if connection.draft_model!.blank?

    true
  end

  def skip_agent(reason)
    puts "Skipping agent baseline: #{reason}."
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

  # Each text is labelled with the most recent matching card before it; text before the first matching card is dropped.
  def conversation_queries(conversation, enabled)
    product = nil
    conversation.messages.incoming.where(private: false).order(:id).filter_map do |message|
      product = enabled[card_item_id(message)] || product
      next if product.nil? || message.content.blank? || message.content.match?(CARD_TEXT)

      Query.new(text: message.content, kind: :product, id: product.id, conversation: conversation)
    end
  end

  def card_item_id(message)
    (message.content_attributes['shopee_item_id'].presence || message.content.to_s[Captain::Products::MatchService::CARD_CONTENT_REGEX, 1]).to_s
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

  # Returns [[kind, id], ...] in tool-call order, or nil when the run errored (not a miss).
  def agent_ranking(query)
    conversation = agent_conversation(query)
    return if conversation.nil?

    runner = Captain::Assistant::AgentRunnerService.new(assistant: @assistant, conversation: conversation, run_options: draft_run_options)
    response = runner.generate_response(message_history: [{ role: 'user', content: query.text }])
    return if run_errored?(response, runner)

    ids = runner.retrieved_ids
    ids[:product_ids].map { |id| [:product, id] } + ids[:faq_ids].map { |id| [:faq, id] }
  end

  def agent_conversation(query) = query.conversation || @assistant.inboxes.first&.conversations&.first

  # generate_response rescues failures into an error response; those runs are not misses.
  def run_errored?(response, runner)
    response.nil? || response['error'] || runner.last_run_result&.error
  end

  def draft_run_options
    Captain::Assistant::AgentRunnerService::RunOptions.new(
      source: Captain::Assistant::AgentRunnerService::DRAFT_SOURCE, runtime_configuration: { draft: true }
    )
  end

  def print_report(rows)
    puts table_row('variant', 'n', "hit@#{top_k}", 'MRR')
    rows.each { |variant, scored| puts metrics_row(variant, scored) }
    print_misses(rows)
  end

  def metrics_row(variant, scored)
    return table_row(variant, 0, 'n/a', 'n/a') if scored.empty?

    ranks = scored.map { |query, ranking| rank_of(query, ranking) }
    hit = ranks.count(&:positive?).fdiv(ranks.size)
    mrr = ranks.sum { |rank| rank.positive? ? 1.0 / rank : 0.0 }.fdiv(ranks.size)
    table_row(variant, ranks.size, hit.round(3).to_s.ljust(5, '0'), mrr.round(3).to_s.ljust(5, '0'))
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
