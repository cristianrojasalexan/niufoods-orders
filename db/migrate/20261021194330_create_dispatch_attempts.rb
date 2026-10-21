# Audit log of every delivery attempt of an order to its store.
class CreateDispatchAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :dispatch_attempts do |t|
      t.references :order, null: false, foreign_key: true
      t.integer :dispatch_cycle, null: false
      t.integer :attempt_number, null: false
      t.uuid :dispatch_token, null: false
      # success, transient (worth retrying), permanent, or stale (the worker
      # lost its lease and its result was discarded).
      t.string :outcome, null: false
      t.integer :http_status
      t.string :error_message
      t.integer :duration_ms, null: false

      t.datetime :created_at, null: false
    end
    add_check_constraint :dispatch_attempts, "outcome IN ('success', 'transient', 'permanent', 'stale')",
                         name: "dispatch_attempts_outcome_valid"
  end
end
