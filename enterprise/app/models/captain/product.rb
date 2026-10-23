# == Schema Information
#
# Table name: captain_products
#
#  id             :bigint           not null, primary key
#  context        :text
#  description    :text
#  embedding      :vector(1536)
#  enabled        :boolean          default(TRUE), not null
#  name           :string           not null
#  prompt         :text
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#  assistant_id   :bigint           not null
#  shopee_item_id :string
#
# Indexes
#
#  idx_captain_products_on_assistant_shopee_item  (assistant_id,shopee_item_id) UNIQUE WHERE (shopee_item_id IS NOT NULL)
#  index_captain_products_on_account_id           (account_id)
#  index_captain_products_on_assistant_id         (assistant_id)
#  vector_idx_captain_products_embedding          (embedding) USING ivfflat
#
class Captain::Product < ApplicationRecord
  self.table_name = 'captain_products'

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant'
  has_neighbors :embedding, normalize: true

  validates :name, presence: true
  validates :shopee_item_id, uniqueness: { scope: :assistant_id }, allow_blank: true

  after_commit :update_product_embedding

  scope :enabled, -> { where(enabled: true) }

  def self.search(query, assistant:)
    embedding = Captain::Llm::EmbeddingService.new(account_id: assistant.account_id).get_embedding(query)
    enabled.where(assistant_id: assistant.id).nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(3)
  end

  def embedding_text
    "#{name}: #{description}\n#{context}"
  end

  private

  def update_product_embedding
    return unless saved_change_to_name? || saved_change_to_description? || saved_change_to_context?

    Captain::Llm::UpdateEmbeddingJob.perform_later(self, embedding_text)
  end
end
