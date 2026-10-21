# State of the simulated stores. They stand in for the systems of each
# restaurant, so these tables do not reference the orders domain.
class CreateSimulatedStoreTables < ActiveRecord::Migration[8.1]
  def change
    create_table :simulated_store_modes, primary_key: :store_code, id: :string do |t|
      t.string :mode, null: false

      t.timestamps
    end

    # One row per order a store was asked to receive, keyed by the
    # Idempotency-Key the API sends with every dispatch.
    create_table :simulated_store_requests do |t|
      t.string :store_code, null: false
      t.string :idempotency_key, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :received_at
      t.jsonb :payload

      t.timestamps
    end
    add_index :simulated_store_requests, %i[store_code idempotency_key], unique: true
    add_check_constraint :simulated_store_requests, "received_at IS NULL OR payload IS NOT NULL",
                         name: "simulated_store_requests_receipt_has_payload"
  end
end
