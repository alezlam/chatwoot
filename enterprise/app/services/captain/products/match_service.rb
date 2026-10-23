class Captain::Products::MatchService
  # content_attributes is a json column holding a JSON string, so unwrap it before reading keys (see Message.not_forwarded).
  SHOPEE_ITEM_ID_SQL = "(messages.content_attributes #>> '{}')::jsonb ->> 'shopee_item_id'".freeze
  # Messages imported before the attribute existed carry the item id only in the text.
  CARD_CONTENT_SQL_PATTERN = '^Product: [0-9]+$'.freeze
  CARD_CONTENT_REGEX = /\AProduct: (\d+)\z/

  def initialize(conversation:, assistant:)
    @conversation = conversation
    @assistant = assistant
  end

  def perform
    item_id = latest_card_item_id
    return if item_id.blank?

    @assistant.products.enabled.find_by(shopee_item_id: item_id)
  end

  private

  def latest_card_item_id
    message = @conversation.messages.incoming
                           .where("#{SHOPEE_ITEM_ID_SQL} IS NOT NULL OR messages.content ~ ?", CARD_CONTENT_SQL_PATTERN)
                           .reorder(id: :desc)
                           .first
    return if message.nil?

    message.content_attributes['shopee_item_id'].presence || message.content[CARD_CONTENT_REGEX, 1]
  end
end
