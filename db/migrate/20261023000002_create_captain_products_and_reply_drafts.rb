class CreateCaptainProductsAndReplyDrafts < ActiveRecord::Migration[7.1]
  def change
    create_products
    create_reply_drafts
  end

  private

  def create_products
    create_table :captain_products do |t|
      t.references :account, null: false, index: true
      t.references :assistant, null: false, index: true
      t.string :name, null: false
      t.text :description
      t.text :prompt
      t.text :context
      t.string :shopee_item_id
      t.boolean :enabled, null: false, default: true
      t.vector :embedding, limit: 1536

      t.timestamps
    end

    add_index :captain_products, [:assistant_id, :shopee_item_id], unique: true, where: 'shopee_item_id IS NOT NULL',
                                                                   name: 'idx_captain_products_on_assistant_shopee_item'
    add_index :captain_products, :embedding, using: :ivfflat, name: 'vector_idx_captain_products_embedding',
                                             opclass: :vector_cosine_ops
  end

  def create_reply_drafts
    create_table :captain_reply_drafts do |t|
      t.references :account, null: false, index: true
      t.references :conversation, null: false, index: { unique: true }
      t.references :assistant, null: false, index: true
      t.references :product, index: true
      t.bigint :last_message_id, null: false
      t.text :content, null: false

      t.timestamps
    end
  end
end
