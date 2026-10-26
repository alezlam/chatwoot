# == Schema Information
#
# Table name: captain_products
#
#  id             :bigint           not null, primary key
#  confirmed      :boolean          default(FALSE), not null
#  context        :text
#  description    :text
#  embedding      :vector(1536)
#  enabled        :boolean          default(TRUE), not null
#  hits           :integer          default(0), not null
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

  # Blank must be NULL: the unique index only excludes NULL, so two '' rows would collide.
  normalizes :shopee_item_id, with: ->(value) { value.to_s.strip.presence }

  validates :name, presence: true
  validates :shopee_item_id, uniqueness: { scope: :assistant_id }, allow_blank: true

  scope :enabled, -> { where(enabled: true) }
end
