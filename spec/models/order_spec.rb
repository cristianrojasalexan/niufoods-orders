require "rails_helper"

RSpec.describe Order, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:restaurant) }
    it { is_expected.to have_many(:order_items).dependent(:destroy) }
    it { is_expected.to have_many(:products).through(:order_items) }
  end

  describe "validations" do
    subject(:order) { build(:order) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:customer_name) }
    it { is_expected.to validate_presence_of(:customer_phone) }

    it "only accepts pickup or delivery as order type" do
      order.order_type = "dine_in"

      expect(order).not_to be_valid
      expect(order.errors[:order_type]).to include("is not included in the list")
    end

    it "requires a delivery address for delivery orders" do
      order.order_type = "delivery"

      expect(order).not_to be_valid
      expect(order.errors[:delivery_address]).to include("can't be blank")
    end

    it "does not require an address for pickup orders" do
      expect(build(:order, order_type: "pickup", delivery_address: nil)).to be_valid
    end

    it "requires at least one item" do
      order.order_items.clear

      expect(order).not_to be_valid
      expect(order.errors[:order_items]).to include("must include at least one product")
    end

    it "rejects the same product twice" do
      product = order.order_items.first.product
      order.order_items.build(product: product, quantity: 1)

      expect(order).not_to be_valid
      expect(order.errors[:order_items]).to include("must not repeat a product")
    end

    it "rejects malformed phone numbers" do
      order.customer_phone = "call me"

      expect(order).not_to be_valid
    end
  end

  describe "normalization" do
    it "strips the customer name and blank addresses" do
      order = build(:order, customer_name: "  Ana Pérez ", delivery_address: "   ")

      expect(order.customer_name).to eq("Ana Pérez")
      expect(order.delivery_address).to be_nil
    end

    it "removes spaces and separators from the phone" do
      expect(build(:order, customer_phone: "+56 9 1234-5678").customer_phone).to eq("+56912345678")
    end
  end

  describe "total amount" do
    let(:roll) { create(:product, price: 8990) }
    let(:gyozas) { create(:product, price: 4490) }

    def build_order(total_amount: nil)
      build(:order, total_amount: total_amount).tap do |order|
        order.order_items.clear
        order.order_items.build(product: roll, quantity: 2)
        order.order_items.build(product: gyozas, quantity: 1)
      end
    end

    it "is calculated from the items" do
      order = build_order
      order.save!

      expect(order.total_amount).to eq(2 * 8990 + 4490)
      expect(order.order_items.map(&:subtotal)).to contain_exactly(17_980, 4490)
    end

    it "ignores any total assigned from outside" do
      order = build_order(total_amount: 1)
      order.save!

      expect(order.total_amount).to eq(22_470)
    end

    it "keeps the prices of the moment the order was created" do
      order = build_order
      order.save!
      roll.update!(price: 9990)

      expect(order.reload.total_amount).to eq(22_470)
      expect(order.order_items.find_by(product: roll).unit_price).to eq(8990)
    end
  end

  describe "number" do
    it "combines the restaurant code with a zero padded sequence" do
      restaurant = create(:restaurant, code: "LCON")
      order = create(:order, restaurant: restaurant)

      expect(order.number).to eq(format("LCON-%06d", order.id))
    end

    it "is unique for every order" do
      numbers = Array.new(3) { create(:order).number }

      expect(numbers.uniq.size).to eq(3)
    end
  end

  describe "database constraints" do
    let(:order) { create(:order) }

    it "rejects delivery orders without address" do
      expect { order.update_columns(order_type: "delivery", delivery_address: nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /orders_delivery_requires_address/)
    end

    it "rejects unknown order types" do
      expect { order.update_column(:order_type, "dine_in") }
        .to raise_error(ActiveRecord::StatementInvalid, /orders_order_type_valid/)
    end

    it "rejects negative totals" do
      expect { order.update_column(:total_amount, -1) }
        .to raise_error(ActiveRecord::StatementInvalid, /orders_total_amount_non_negative/)
    end
  end
end
