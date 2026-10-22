module Orders
  # Opens a new dispatch cycle for a failed order, from the dashboard.
  #
  # One conditional UPDATE moves the order back to pending only while it is
  # still failed in the cycle the person saw. Checking the status alone is
  # not enough: a second click on the same failure could arrive after the
  # new cycle already failed again and open yet another one. With the cycle,
  # every click after the first changes nothing, however fast the store
  # answers. The new cycle starts with its attempts at 0, so it gets
  # MAX_ATTEMPTS_PER_CYCLE again, and the attempts of earlier cycles stay in
  # dispatch_attempts.
  class Redispatch
    REOPEN_SQL = <<~SQL.squish.freeze
      UPDATE orders
      SET dispatch_status = 'pending',
          dispatch_cycle = dispatch_cycle + 1,
          dispatch_attempts_count = 0,
          next_dispatch_at = now(),
          dispatch_token = NULL,
          dispatch_lease_expires_at = NULL,
          updated_at = now()
      WHERE id = :id AND dispatch_status = 'failed' AND dispatch_cycle = :cycle
      RETURNING dispatch_cycle
    SQL

    def self.call(order, cycle:)
      new(order, cycle: cycle).call
    end

    # cycle: the failed cycle being retried, as shown to the person.
    def initialize(order, cycle:)
      @order = order
      @cycle = cycle
    end

    # Returns the number of the new cycle, or nil when the order was no
    # longer failed in that cycle and nothing changed.
    def call
      sql = Order.sanitize_sql_array([ REOPEN_SQL, { id: order.id, cycle: cycle } ])
      new_cycle = Order.connection.exec_query(sql, "Order Redispatch").first&.fetch("dispatch_cycle")
      enqueue_dispatch if new_cycle
      new_cycle
    end

    private

    attr_reader :order, :cycle

    # The order is already pending and due, so if Redis is not available the
    # dispatch recovery enqueues it later.
    def enqueue_dispatch
      ActiveRecord.after_all_transactions_commit do
        DispatchOrderJob.perform_async(order.id)
      rescue RedisClient::Error => e
        Rails.logger.warn("Redispatch of order #{order.number} not enqueued (#{e.class}: #{e.message}); " \
                          "it stays pending for the dispatch recovery")
      end
    end
  end
end
