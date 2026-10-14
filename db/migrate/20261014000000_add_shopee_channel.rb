class AddShopeeChannel < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_shopee do |t|
      t.integer :account_id, null: false
      t.bigint :shop_id, null: false
      t.string :access_token, null: false
      t.datetime :expires_at, null: false
      t.string :refresh_token, null: false
      t.datetime :refresh_token_expires_at, null: false
      t.timestamps
    end

    add_index :channel_shopee, :shop_id, unique: true
  end
end
