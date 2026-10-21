# Runs one dispatch attempt of an order. The job carries no state: whether
# the order may be delivered, and how many attempts it has left, is decided
# by Orders::Dispatcher in PostgreSQL. A duplicated or early job is harmless.
class DispatchOrderJob
  include Sidekiq::Job

  sidekiq_options queue: "dispatch", retry: false

  def perform(order_id)
    Orders::Dispatcher.call(order_id)
  end
end
