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

  describe "dispatch" do
    it "enqueues the dispatch of a new order" do
      result = call

      expect(DispatchOrderJob.jobs.map { |job| job["args"] }).to eq([ [ result.order.id ] ])
    end

    it "enqueues the job only after the enclosing transaction commits" do
      ActiveRecord::Base.transaction(requires_new: true) do
        call
        expect(DispatchOrderJob.jobs).to be_empty
      end

      expect(DispatchOrderJob.jobs.size).to eq(1)
    end

    it "does not enqueue anything for invalid requests or retries" do
      described_class.call(payload, idempotency_key: "retry-1")
      DispatchOrderJob.clear

      call("delivery_address" => nil)
      described_class.call(payload, idempotency_key: "retry-1")

      expect(DispatchOrderJob.jobs).to be_empty
    end

    it "leaves new orders pending" do
      expect(call.order).to have_attributes(dispatch_status: "pending", dispatch_attempts_count: 0)
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

  describe "with an Idempotency-Key" do
    let(:key) { "a1b2c3d4-retry" }

    def call_with_key(overrides = {})
      described_class.call(payload.merge(overrides), idempotency_key: key)
    end

    it "creates the order the first time and stores the key with the fingerprint" do
      result = call_with_key

      expect(result.status).to eq(:created)
      expect(result.order).to have_attributes(idempotency_key: key, request_fingerprint: match(/\A\h{64}\z/))
    end

    it "returns the same order when the same request is retried" do
      first = call_with_key

      retry_result = nil
      expect { retry_result = call_with_key }.not_to change(Order, :count)
      expect(retry_result.status).to eq(:replayed)
      expect(retry_result).to be_success
      expect(retry_result.order).to eq(first.order)
    end

    it "treats a retry with the items reordered or split as the same request" do
      first = call_with_key

      retry_result = call_with_key("items" => [
        { "product_id" => 5, "quantity" => 1 },
        { "product_id" => 1, "quantity" => 1 },
        { "product_id" => 1, "quantity" => 1 }
      ])

      expect(retry_result.status).to eq(:replayed)
      expect(retry_result.order).to eq(first.order)
    end

    it "is a conflict when the key is reused with a different request" do
      call_with_key

      result = call_with_key("items" => [ { "product_id" => 1, "quantity" => 5 } ])

      expect(result.status).to eq(:conflict)
      expect(result).not_to be_success
      expect(result.errors).to contain_exactly(have_attributes(field: nil, code: "idempotency_conflict"))
      expect(Order.count).to eq(1)
    end

    it "returns the stored order on retries even after the catalog changed" do
      first = call_with_key("total_amount" => 22_470)
      roll.update!(price: 9990)

      retry_result = call_with_key("total_amount" => 22_470)

      expect(retry_result.status).to eq(:replayed)
      expect(retry_result.order.total_amount).to eq(22_470)
      expect(retry_result.order).to eq(first.order)
    end

    it "does not reserve the key when the request is invalid" do
      invalid = call_with_key("delivery_address" => nil)
      valid = call_with_key

      expect(invalid.status).to eq(:invalid)
      expect(valid.status).to eq(:created)
    end

    it "still rejects a retry with the wrong types" do
      call_with_key

      expect(call_with_key("items" => [ { "product_id" => 1, "quantity" => 2.5 } ]).status).to eq(:invalid)
    end

    it "lets orders without a key be created as many times as requested" do
      2.times { described_class.call(payload) }

      expect(Order.count).to eq(2)
      expect(Order.pluck(:idempotency_key)).to eq([ nil, nil ])
    end

    context "when a concurrent request stores the key first" do
      it "replays the winning order if it has the same request" do
        winner = call_with_key.order
        allow(Order).to receive(:find_by).and_call_original
        allow(Order).to receive(:find_by).with(idempotency_key: key).and_return(nil, winner)

        result = call_with_key

        expect(result.status).to eq(:replayed)
        expect(result.order).to eq(winner)
        expect(Order.count).to eq(1)
      end

      it "is a conflict if the winning order has another request" do
        winner = call_with_key("items" => [ { "product_id" => 1, "quantity" => 5 } ]).order
        allow(Order).to receive(:find_by).and_call_original
        allow(Order).to receive(:find_by).with(idempotency_key: key).and_return(nil, winner)

        expect(call_with_key.status).to eq(:conflict)
      end
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
