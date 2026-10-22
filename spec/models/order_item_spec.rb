require "rails_helper"

RSpec.describe OrderItem, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:order) }
    it { is_expected.to belong_to(:product) }
  end

  describe "validations" do
    subject(:item) { build(:order_item) }

    it { is_expected.to validate_numericality_of(:quantity).only_integer.is_greater_than(0).is_less_than_or_equal_to(99) }

    it "requires a price" do
      item.product = nil

      expect(item).not_to be_valid
      expect(item.errors[:unit_price]).to be_present
    end
  end

  describe "pricing" do
    let(:product) { create(:product, price: 3990) }

    it "takes the unit price from the product and calculates the subtotal" do
      item = build(:order_item, product: product, quantity: 3)
      item.validate

      expect(item.unit_price).to eq(3990)
      expect(item.subtotal).to eq(11_970)
    end

    it "always takes the catalog price for a new item, ignoring an assigned one" do
      item = build(:order_item, product: product, quantity: 2, unit_price: 1)
      item.validate

      expect(item).to have_attributes(unit_price: 3990, subtotal: 7980)
    end

    it "does not take a new catalog price after creation" do
      item = create(:order_item, product: product, quantity: 1)
      product.update!(price: 4990)

      item.update!(quantity: 2)

      expect(item.reload).to have_attributes(unit_price: 3990, subtotal: 7980)
    end
  end

  describe "order total" do
    let(:order) { create(:order) }
    let(:item) { order.order_items.first }

    def subtotals_sum
      order.order_items.sum(:subtotal)
    end

    it "is updated when an item is changed on its own" do
      item.update!(quantity: 2)

      expect(order.reload.total_amount).to eq(2 * item.unit_price)
      expect(order.total_amount).to eq(subtotals_sum)
    end

    it "is updated when an item is added to an existing order" do
      create(:order_item, order: order, quantity: 3)

      expect(order.reload.total_amount).to eq(subtotals_sum)
      expect(order.order_items.count).to eq(2)
    end

    it "cannot be changed once its order was deleted" do
      stale_item = OrderItem.find(item.id)
      order.destroy!

      expect { stale_item.update!(quantity: 2) }.to raise_error(ActiveRecord::RecordNotFound, /no longer exists/)
    end

    it "is updated when an item is removed" do
      extra = create(:order_item, order: order, quantity: 1)

      extra.destroy!

      expect(order.reload.total_amount).to eq(item.subtotal)
    end

    # Another process changes an item between loading the order and loading
    # its items, and again before the order is saved: the total the order
    # calculates in memory is stale and differs from the one it loaded.
    it "stays consistent when an order with stale items is saved" do
      stale_order = Order.find(order.id)
      OrderItem.find(item.id).update!(quantity: 3)
      stale_order.order_items.load
      OrderItem.find(item.id).update!(quantity: 1)

      stale_order.update!(customer_name: "Camila Rojas")

      expect(order.reload.total_amount).to eq(item.unit_price)
      expect(order.total_amount).to eq(subtotals_sum)
    end
  end

  describe "removal" do
    let!(:order) { create(:order, items_count: 2) }

    it "can remove an item while another one remains" do
      order.order_items.first.destroy!

      expect(order.order_items.reload.size).to eq(1)
    end

    it "cannot remove the last item of an order" do
      first, last = order.order_items.to_a
      first.destroy!

      expect { last.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(last.errors[:base]).to include(/at least one item/)
      expect(order.reload.total_amount).to eq(last.subtotal)
    end

    it "cannot remove the last item by marking it and destroying it outside its order's save" do
      first, last = order.order_items.to_a
      first.destroy!

      last.mark_for_destruction
      expect { last.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(OrderItem.where(order_id: order.id).pluck(:id)).to eq([ last.id ])
    end

    it "can replace the last item in the same save of its order" do
      order.order_items.first.destroy!
      last = order.order_items.reload.sole
      replacement = create(:product, price: 2490)

      last.mark_for_destruction
      order.order_items.build(product: replacement, quantity: 2)
      order.save!

      expect(order.reload.order_items.map(&:product)).to eq([ replacement ])
      expect(order.total_amount).to eq(4980)
    end

    # The order in memory still holds an item another process already
    # removed, so its own validation passes; the count in the database
    # after the save is what stops it.
    it "cannot lose its last item through a save with stale items" do
      first, last = order.order_items.to_a
      OrderItem.find(first.id).destroy!

      last.mark_for_destruction
      expect(order.valid?).to be(true)
      expect { order.save! }.to raise_error(ActiveRecord::RecordNotSaved, /must keep at least one item/)
      expect(OrderItem.where(order_id: order.id).pluck(:id)).to eq([ last.id ])
    end

    # save (without !) would turn RecordInvalid into a Rollback that the
    # outer transaction swallows, committing the item already removed.
    it "cannot lose its last item through a save inside another transaction" do
      first, last = order.order_items.to_a
      OrderItem.find(first.id).destroy!

      expect do
        Order.transaction(requires_new: true) do
          last.mark_for_destruction
          order.save
        end
      end.to raise_error(ActiveRecord::RecordNotSaved)
      expect(OrderItem.where(order_id: order.id).pluck(:id)).to eq([ last.id ])
    end

    it "still lets the whole order be destroyed" do
      expect { order.destroy! }.to change(OrderItem, :count).by(-2)
    end
  end

  describe "order and product" do
    let(:item) { create(:order_item) }

    it "cannot be moved to another order" do
      expect { item.order = create(:order) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { item.update!(order_id: create(:order).id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "cannot change its product" do
      expect { item.update!(product: create(:product)) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end
  end

  describe "database constraints" do
    let(:item) { create(:order_item) }

    it "rejects non-positive quantities" do
      expect { item.update_columns(quantity: 0, subtotal: 0) }
        .to raise_error(ActiveRecord::StatementInvalid, /order_items_quantity_positive/)
    end

    it "rejects a subtotal that does not match price and quantity" do
      expect { item.update_column(:subtotal, item.subtotal + 1) }
        .to raise_error(ActiveRecord::StatementInvalid, /order_items_subtotal_consistent/)
    end

    it "rejects the same product twice in one order" do
      expect { create(:order_item, order: item.order, product: item.product) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
