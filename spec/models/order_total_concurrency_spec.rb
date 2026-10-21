require "rails_helper"

# Runs real concurrent transactions, so it cannot use the transactional
# fixtures of the rest of the suite and cleans up its own records.
RSpec.describe "Order total under concurrent item changes" do
  self.use_transactional_tests = false

  let!(:order) do
    build(:order, items_count: 0).tap do |order|
      order.order_items.clear
      order.order_items.build(product: create(:product, price: 4990), quantity: 1)
      order.order_items.build(product: create(:product, price: 9990), quantity: 1)
      order.save!
    end
  end
  let(:first_item) { order.order_items.min_by(&:id) }
  let(:second_item) { order.order_items.max_by(&:id) }

  after do
    OrderItem.delete_all
    Order.delete_all
    Product.delete_all
    Restaurant.delete_all
  end

  it "never stores a total computed before another item change was committed" do
    first_changed = Queue.new
    release_first = Queue.new

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        OrderItem.transaction do
          OrderItem.find(first_item.id).update!(quantity: 3)
          first_changed << true
          release_first.pop
        end
      end
    end

    first_changed.pop
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        OrderItem.find(second_item.id).update!(quantity: 2)
      end
    end

    sleep 0.3
    second_waited = second.alive?
    release_first << true
    [ first, second ].each(&:join)

    order.reload
    expect(order.order_items.sum(:subtotal)).to eq(3 * 4990 + 2 * 9990)
    expect(order.total_amount).to eq(order.order_items.sum(:subtotal))
    expect(second_waited).to be(true)
  end

  it "does not deadlock when an order is destroyed while one of its items is being changed" do
    errors = Queue.new
    order_locked = Queue.new
    release_change = Queue.new

    # Same lock order as an item update: the order first, then the item.
    change = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        OrderItem.transaction do
          item = OrderItem.find(first_item.id)
          Order.where(id: order.id).lock.pluck(:id)
          order_locked << true
          release_change.pop
          item.update!(quantity: 2)
        end
      end
    rescue StandardError => e
      errors << e
    end

    order_locked.pop
    destroy = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { Order.find(order.id).destroy! }
    rescue StandardError => e
      errors << e
    end

    sleep 0.3
    release_change << true
    [ change, destroy ].each(&:join)

    expect(errors.size).to eq(0), -> { "unexpected error: #{errors.pop.class}" }
    expect(Order.exists?(order.id)).to be(false)
    expect(OrderItem.where(order_id: order.id)).to be_empty
  end
end
