require "rails_helper"

# Real concurrent requests with the same Idempotency-Key. Each thread uses its
# own database connection, so the transactional fixtures of the rest of the
# suite cannot be used and the spec cleans up its own records.
RSpec.describe Orders::Create, "with concurrent requests" do
  self.use_transactional_tests = false

  # The pool has 5 connections and the main thread keeps one.
  let(:threads) { 4 }

  let!(:restaurant) { create(:restaurant) }
  let!(:product) { create(:product, price: 8990) }
  let(:key) { "concurrent-#{SecureRandom.hex(4)}" }

  def payload(quantity: 1)
    {
      "restaurant_id" => restaurant.id,
      "order_type" => "pickup",
      "customer" => { "name" => "Ana Pérez", "phone" => "+56912345678" },
      "items" => [ { "product_id" => product.id, "quantity" => quantity } ]
    }
  end

  # Runs one call per payload, each in its own thread and connection.
  def run_concurrently(payloads)
    payloads.map do |body|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(body, idempotency_key: key)
        end
      end
    end.map(&:value)
  end

  # Makes every thread pass the lookup of the key before any of them
  # inserts, so they really compete for the unique index instead of the
  # later ones simply finding the first order.
  def hold_inserts_until_all_arrive(parties)
    barrier = Concurrent::CyclicBarrier.new(parties)
    allow_any_instance_of(described_class).to receive(:save).and_wrap_original do |original, *args|
      barrier.wait(5) || raise("not every request reached the insert")
      original.call(*args)
    end
  end

  after do
    OrderItem.delete_all
    Order.delete_all
    Product.delete_all
    Restaurant.delete_all
  end

  it "creates a single order when the same request arrives several times at once" do
    hold_inserts_until_all_arrive(threads)

    results = run_concurrently(Array.new(threads) { payload })

    expect(Order.where(idempotency_key: key).count).to eq(1)
    expect(results.map(&:status).tally).to eq(created: 1, replayed: threads - 1)
    expect(results.map { |result| result.order.id }.uniq).to eq([ Order.find_by(idempotency_key: key).id ])
  end

  it "keeps the first order and reports a conflict to different requests that reuse the key" do
    hold_inserts_until_all_arrive(threads)

    results = run_concurrently(Array.new(threads) { |index| payload(quantity: index + 1) })

    order = Order.find_by(idempotency_key: key)
    winner = results.find { |result| result.status == :created }
    expect(Order.where(idempotency_key: key).count).to eq(1)
    expect(results.map(&:status).tally).to eq(created: 1, conflict: threads - 1)
    expect(winner.order).to eq(order)
    expect(results.reject { |result| result.equal?(winner) }.flat_map(&:errors).map(&:code).uniq)
      .to eq([ "idempotency_conflict" ])
  end

  it "stores the items and total of the winning request only" do
    hold_inserts_until_all_arrive(threads)

    run_concurrently(Array.new(threads) { payload(quantity: 2) })

    order = Order.find_by(idempotency_key: key)
    expect(OrderItem.where(order: order).pluck(:quantity)).to eq([ 2 ])
    expect(order.total_amount).to eq(2 * 8990)
    expect(OrderItem.count).to eq(1)
  end

  it "creates a single order when the requests race without coordination" do
    results = run_concurrently(Array.new(threads) { payload })

    expect(Order.where(idempotency_key: key).count).to eq(1)
    expect(results.map(&:status)).to all(be_in(%i[created replayed]))
    expect(results.count { |result| result.status == :created }).to eq(1)
  end
end
