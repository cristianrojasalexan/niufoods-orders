module Orders
  # Operational figures of one day (in the app time zone), read in a single
  # query: orders and amount received, how many reached their store and how
  # long that took.
  #
  #   summary = Orders::DailySummary.call
  #   summary.orders          # => 24
  #   summary.amount          # => 1146940
  #   summary.delivery_rate   # => 0.92, or nil before any dispatch ended
  #   summary.average_delivery_seconds # => 2.4, or nil
  class DailySummary
    Result = Data.define(:orders, :amount, :dispatched, :failed, :average_delivery_seconds) do
      # Over the dispatches that already ended; pending ones do not count yet.
      def delivery_rate
        finished = dispatched + failed
        dispatched.fdiv(finished) if finished.positive?
      end
    end

    COLUMNS = [
      "COUNT(*)",
      "COALESCE(SUM(total_amount), 0)",
      "COUNT(*) FILTER (WHERE dispatch_status = 'dispatched')",
      "COUNT(*) FILTER (WHERE dispatch_status = 'failed')",
      "AVG(EXTRACT(EPOCH FROM dispatched_at - created_at)) FILTER (WHERE dispatch_status = 'dispatched')"
    ].map { |column| Arel.sql(column) }.freeze

    def self.call(day: Time.zone.today)
      orders, amount, dispatched, failed, average = Order.where(created_at: day.all_day).pick(*COLUMNS)
      Result.new(orders: orders, amount: amount, dispatched: dispatched, failed: failed,
                 average_delivery_seconds: average&.to_f)
    end
  end
end
