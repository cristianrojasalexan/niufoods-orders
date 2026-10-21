# The dispatch state lives in PostgreSQL, the single source of truth;
# Sidekiq only runs the attempts.
class AddDispatchStateToOrders < ActiveRecord::Migration[8.1]
  def change
    change_table :orders, bulk: true do |t|
      t.string :dispatch_status, null: false, default: "pending"
      # A cycle is a series of attempts; a manual redispatch opens a new one.
      t.integer :dispatch_cycle, null: false, default: 1
      t.integer :dispatch_attempts_count, null: false, default: 0
      t.datetime :next_dispatch_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      # Identifies the worker that holds the dispatch and until when.
      t.uuid :dispatch_token
      t.datetime :dispatch_lease_expires_at
      t.datetime :dispatched_at
      t.string :last_dispatch_error
    end

    add_check_constraint :orders, "dispatch_status IN ('pending', 'dispatching', 'dispatched', 'failed')",
                         name: "orders_dispatch_status_valid"
    add_check_constraint :orders,
                         "dispatch_status <> 'dispatching' OR (dispatch_token IS NOT NULL AND dispatch_lease_expires_at IS NOT NULL)",
                         name: "orders_dispatching_has_lease"
    add_check_constraint :orders, "dispatch_status <> 'dispatched' OR dispatched_at IS NOT NULL",
                         name: "orders_dispatched_has_timestamp"
    add_check_constraint :orders, "dispatch_attempts_count >= 0", name: "orders_dispatch_attempts_non_negative"

    # Finds the orders a dispatch is due for.
    add_index :orders, %i[dispatch_status next_dispatch_at], where: "dispatch_status IN ('pending', 'dispatching')",
                                                             name: "index_orders_on_dispatch_due"
    add_index :orders, :dispatch_status
  end
end
