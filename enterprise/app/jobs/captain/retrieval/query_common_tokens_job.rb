class Captain::Retrieval::QueryCommonTokensJob < ApplicationJob
  queue_as :scheduled_jobs

  WINDOW = 30.days
  MIN_MESSAGES = 200
  COMMON_RATIO = 0.5
  CACHE_TTL = 2.days
  CARD_TEXT = /\A(Product|Order): \S+\z/
  BATCH_SIZE = 1000

  def perform
    Captain::Assistant.find_each { |assistant| cache_common_tokens(assistant) }
  end

  private

  def cache_common_tokens(assistant)
    inbox_ids = assistant.captain_inboxes.pluck(:inbox_id)
    return if inbox_ids.empty?

    total, counts = count_tokens(inbox_ids)
    return if total < MIN_MESSAGES

    common = counts.select { |_token, count| count > total * COMMON_RATIO }.keys.to_set
    Rails.cache.write(Captain::Retrieval::LexicalRetriever.cache_key(assistant), common, expires_in: CACHE_TTL)
  end

  def count_tokens(inbox_ids)
    total = 0
    counts = Hash.new(0)
    scope = Message.incoming.where(private: false, inbox_id: inbox_ids, created_at: WINDOW.ago..)
                   .where.not(content: [nil, ''])
    scope.in_batches(of: BATCH_SIZE) do |batch|
      batch.pluck(:content).each do |content|
        next if content.match?(CARD_TEXT)

        total += 1
        Captain::Retrieval::Tokenizer.tokens(content).uniq.each { |token| counts[token] += 1 }
      end
    end
    [total, counts]
  end
end
