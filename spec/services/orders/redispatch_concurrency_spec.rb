require "rails_helper"

# Real concurrent retries of the same failed order, as when two people click
# "Reintentar despacho" at once. Each thread uses its own database
# connection, so the transactional fixtures of the rest of the suite cannot
# be used and the spec cleans up its own records.
RSpec.describe Orders::Redispatch, "with concurrent retries" do
  self.use_transactional_tests = false

  # The pool has 5 connections and the main thread keeps one.
  let(:threads) { 4 }

  after do
    OrderItem.delete_all
    Order.delete_all
    Product.delete_all
    Restaurant.delete_all
  end

  it "opens a single new cycle and enqueues a single dispatch" do
    order = create(:order).tap { |o| o.update_columns(dispatch_status: "failed", dispatch_attempts_count: 5) }
    barrier = Concurrent::CyclicBarrier.new(threads)

    cycles = Array.new(threads) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait(5) || raise("not every retry started")
          described_class.call(order)
        end
      end
    end.map(&:value)

    expect(cycles.compact).to eq([ 2 ])
    expect(order.reload).to have_attributes(dispatch_status: "pending", dispatch_cycle: 2, dispatch_attempts_count: 0)
    expect(DispatchOrderJob.jobs.size).to eq(1)
  end
end
