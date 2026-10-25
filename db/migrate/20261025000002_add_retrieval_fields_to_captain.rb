class AddRetrievalFieldsToCaptain < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_products, :confirmed, :boolean, default: false, null: false
    add_column :captain_products, :hits, :integer, default: 0, null: false
    add_column :captain_assistant_responses, :confirmed, :boolean, default: false, null: false
    add_column :captain_assistant_responses, :hits, :integer, default: 0, null: false
    add_column :captain_reply_drafts, :retrieved_product_ids, :jsonb, default: []
    add_column :captain_reply_drafts, :retrieved_faq_ids, :jsonb, default: []
  end
end
