class CreateCaptainChatgptConnections < ActiveRecord::Migration[7.1]
  def change
    create_table :captain_chatgpt_connections do |t|
      t.bigint :account_id, null: false, index: { unique: true }
      t.integer :status, null: false, default: 0
      t.text :access_token
      t.text :refresh_token
      t.text :id_token
      t.string :chatgpt_account_id
      t.string :email
      t.string :plan_type
      t.string :model
      t.datetime :expires_at
      t.jsonb :last_error, null: false, default: {}
      t.jsonb :pending_device, null: false, default: {}

      t.timestamps
    end
  end
end
