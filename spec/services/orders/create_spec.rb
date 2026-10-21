require "rails_helper"

RSpec.describe Orders::Create do
  let!(:restaurant) { create(:restaurant, id: 2, code: "LCON") }
  let!(:roll) { create(:product, id: 1, price: 8990) }
  let!(:gyozas) { create(:product, id: 5, price: 4490) }

  # The reference payload of the technical test.
  let(:payload) do
    {
      "restaurant_id" => 2,
      "order_type" => "delivery",
      "customer" => { "name" => "Ana Pérez", "phone" => "+56912345678" },
      "delivery_address" => "Av. Providencia 1234, Santiago",
      "items" => [
        { "product_id" => 1, "quantity" => 2 },
        { "product_id" => 5, "quantity" => 1 }
      ]
    }
  end

  def call(overrides = {})
    described_class.call(payload.merge(overrides))
  end

  def error_for(result, field)
    result.errors.find { |error| error.field == field }
  end

  describe "with the reference payload" do
    subject(:result) { call }

    it "creates the order with its items" do
      expect(result).to be_success
      expect(result.order).to be_persisted
      expect(result.order.order_items.count).to eq(2)
    end

    it "calculates the total from the catalog prices" do
      expect(result.order.total_amount).to eq(2 * 8990 + 4490)
    end

    it "maps the nested customer to the order columns" do
      expect(result.order).to have_attributes(
        customer_name: "Ana Pérez",
        customer_phone: "+56912345678",
        delivery_address: "Av. Providencia 1234, Santiago",
        restaurant: restaurant,
        order_type: "delivery"
      )
    end

    it "assigns an order number for the restaurant" do
      expect(result.order.number).to match(/\ALCON-\d{6}\z/)
    end
  end

  it "accepts keys as symbols" do
    expect(described_class.call(payload.deep_symbolize_keys)).to be_success
  end

  describe "items" do
    it "consolidates a product listed more than once" do
      result = call("items" => [
        { "product_id" => 1, "quantity" => 1 },
        { "product_id" => 5, "quantity" => 1 },
        { "product_id" => 1, "quantity" => 2 }
      ])

      expect(result).to be_success
      expect(result.order.order_items.map { |item| [ item.product_id, item.quantity ] })
        .to eq([ [ 1, 3 ], [ 5, 1 ] ])
      expect(result.order.total_amount).to eq(3 * 8990 + 4490)
    end

    it "rejects more than the maximum units of a product after consolidating" do
      result = call("items" => [ { "product_id" => 1, "quantity" => 60 }, { "product_id" => 1, "quantity" => 40 } ])

      expect(result).not_to be_success
      expect(error_for(result, "items").code).to eq("invalid_quantity")
    end

    it "requires at least one item" do
      [ nil, [] ].each do |items|
        result = call("items" => items)

        expect(error_for(result, "items")).to have_attributes(code: "blank")
      end
    end

    it "requires items to be an array of objects" do
      expect(error_for(call("items" => "1,2"), "items").code).to eq("invalid_type")
      expect(error_for(call("items" => [ 1 ]), "items[0]").code).to eq("invalid_type")
    end

    it "reports unknown products by position" do
      result = call("items" => [ { "product_id" => 1, "quantity" => 1 }, { "product_id" => 999, "quantity" => 1 } ])

      expect(result.errors).to contain_exactly(have_attributes(field: "items[1].product_id", code: "not_found"))
    end

    it "requires product ids to be positive integers" do
      result = call("items" => [ { "product_id" => "1", "quantity" => 1 } ])

      expect(error_for(result, "items[0].product_id").code).to eq("invalid_type")
    end
  end

  describe "quantities" do
    # Checked as they arrive in the JSON, before any conversion: a decimal
    # is rejected instead of being truncated to an integer.
    [ 2.5, 2.0, "2", nil, 0, -1, 100, true ].each do |quantity|
      it "rejects #{quantity.inspect}" do
        result = call("items" => [ { "product_id" => 1, "quantity" => quantity } ])

        expect(result).not_to be_success
        expect(error_for(result, "items[0].quantity").code).to eq("invalid_quantity")
      end
    end

    it "accepts integers between 1 and 99" do
      expect(call("items" => [ { "product_id" => 1, "quantity" => 99 } ])).to be_success
    end
  end

  describe "total sent by the client" do
    it "is accepted when it matches the calculated total" do
      expect(call("total_amount" => 22_470)).to be_success
    end

    it "is rejected when it does not match" do
      result = call("total_amount" => 1000)

      expect(result).not_to be_success
      expect(result.errors).to contain_exactly(
        have_attributes(field: "total_amount", code: "total_mismatch", message: /22470/)
      )
      expect(Order.count).to eq(0)
    end

    it "must be a non-negative integer" do
      expect(error_for(call("total_amount" => "22470"), "total_amount").code).to eq("invalid_type")
    end

    it "is optional" do
      expect(call("total_amount" => nil)).to be_success
    end
  end

  describe "restaurant" do
    it "must exist" do
      expect(error_for(call("restaurant_id" => 99), "restaurant_id").code).to eq("not_found")
    end

    it "is required and must be a positive integer" do
      expect(error_for(call("restaurant_id" => nil), "restaurant_id").code).to eq("blank")
      expect(error_for(call("restaurant_id" => "2"), "restaurant_id").code).to eq("invalid_type")
    end
  end

  describe "order type and address" do
    it "rejects unknown order types" do
      expect(error_for(call("order_type" => "dine_in"), "order_type")).to be_present
    end

    it "requires an address for delivery" do
      result = call("delivery_address" => nil)

      expect(error_for(result, "delivery_address").code).to eq("blank")
    end

    it "does not store an address for pickup orders" do
      result = call("order_type" => "pickup")

      expect(result).to be_success
      expect(result.order.delivery_address).to be_nil
    end
  end

  describe "customer" do
    it "reports missing data with the field names of the payload" do
      result = call("customer" => { "name" => " ", "phone" => nil })

      expect(result.errors.map(&:field)).to include("customer.name", "customer.phone")
    end

    it "requires the customer to be an object" do
      expect(error_for(call("customer" => "Ana"), "customer").code).to eq("invalid_type")
    end

    it "requires strings" do
      expect(error_for(call("customer" => { "name" => 1, "phone" => "+56912345678" }), "customer.name").code)
        .to eq("invalid_type")
    end

    it "is required" do
      result = call("customer" => nil)

      expect(result.errors.map(&:field)).to include("customer.name", "customer.phone")
    end
  end

  describe "when invalid" do
    it "reports every structural problem at once" do
      result = call("restaurant_id" => "x", "items" => [ { "product_id" => 1, "quantity" => 0 } ])

      expect(result.errors.map(&:field)).to contain_exactly("restaurant_id", "items[0].quantity")
    end

    it "saves nothing" do
      expect { call("delivery_address" => nil) }.not_to change(Order, :count)
      expect(OrderItem.count).to eq(0)
    end
  end
end
