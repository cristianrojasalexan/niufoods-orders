class AddIdempotencyToOrders < ActiveRecord::Migration[8.0]
  def change
    add_column :orders, :idempotency_key, :string
    # SHA-256 of the canonical request, to tell a retry from a different
    # request that reuses the same key.
    add_column :orders, :request_fingerprint, :string

    # Decides which request wins when two arrive with the same key at once.
    add_index :orders, :idempotency_key, unique: true, where: "idempotency_key IS NOT NULL"
    add_check_constraint :orders, "idempotency_key IS NULL OR request_fingerprint IS NOT NULL",
                         name: "orders_idempotency_key_has_fingerprint"
  end
end
