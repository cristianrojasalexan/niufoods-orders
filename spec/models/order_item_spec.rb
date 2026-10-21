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

    it "does not take a new catalog price after creation" do
      item = create(:order_item, product: product, quantity: 1)
      product.update!(price: 4990)

      item.update!(quantity: 2)

      expect(item.reload).to have_attributes(unit_price: 3990, subtotal: 7980)
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
