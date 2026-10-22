# Runs one dispatch attempt of an order. The job carries no state: whether
# the order may be delivered, and how many attempts it has left, is decided
# by Orders::Dispatcher in PostgreSQL. A duplicated or early job is harmless.
class DispatchOrderJob
  include Sidekiq::Job

  sidekiq_options queue: "dispatch", retry: false

  # Enqueues the dispatch of an order once the current transaction commits,
  # or right away outside a transaction, so the worker never reads a state
  # that is not committed yet. wait: seconds before the attempt runs.
  #
  # Every caller has already saved the order as pending and due, so a Redis
  # failure is logged instead of raised: the dispatch recovery enqueues the
  # order again once Redis is back.
  def self.enqueue_after_commit(order, wait: nil)
    ActiveRecord.after_all_transactions_commit do
      wait ? perform_in(wait, order.id) : perform_async(order.id)
    rescue RedisClient::Error => e
      Rails.logger.warn("Dispatch of order #{order.number} not enqueued (#{e.class}: #{e.message}); " \
                        "it stays pending for the dispatch recovery")
    end
  end

  def perform(order_id)
    Orders::Dispatcher.call(order_id)
  end
end
