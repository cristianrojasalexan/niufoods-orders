require "rails_helper"

RSpec.describe "API v1 orders", type: :request do
  let!(:restaurant) { create(:restaurant, id: 2, code: "LCON", name: "Niu Foods Las Condes") }
  let!(:roll) { create(:product, id: 1, name: "Niu Roll Salmón", sku: "SKU-001", price: 8990) }
  let!(:gyozas) { create(:product, id: 5, name: "Gyozas de Pollo x5", sku: "SKU-005", price: 4490) }

  # The reference payload of the technical test, sent as is.
  let(:payload) do
    {
      restaurant_id: 2,
      order_type: "delivery",
      customer: { name: "Ana Pérez", phone: "+56912345678" },
      delivery_address: "Av. Providencia 1234, Santiago",
      items: [
        { product_id: 1, quantity: 2 },
        { product_id: 5, quantity: 1 }
      ]
    }
  end

  let(:json) { response.parsed_body }

  def post_order(body = payload)
    post api_v1_orders_path, params: body, as: :json
  end

  describe "POST /api/v1/orders" do
    context "with the reference payload" do
      it "creates the order and returns 201 with its location" do
        expect { post_order }.to change(Order, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(response.location).to eq(api_v1_order_url(Order.last))
      end

      it "returns the order with the total calculated by the server" do
        post_order

        expect(json).to include(
          "number" => match(/\ALCON-\d{6}\z/),
          "order_type" => "delivery",
          "customer" => { "name" => "Ana Pérez", "phone" => "+56912345678" },
          "delivery_address" => "Av. Providencia 1234, Santiago",
          "total_amount" => 22_470,
          "currency" => "CLP"
        )
        expect(json["restaurant"]).to eq("id" => 2, "code" => "LCON", "name" => "Niu Foods Las Condes")
        expect(json["items"]).to contain_exactly(
          include("product_id" => 1, "sku" => "SKU-001", "quantity" => 2, "unit_price" => 8990, "subtotal" => 17_980),
          include("product_id" => 5, "sku" => "SKU-005", "quantity" => 1, "unit_price" => 4490, "subtotal" => 4490)
        )
      end
    end

    it "ignores attributes outside the contract" do
      post_order(payload.merge(number: "HACK-1", total: 1, items: [ { product_id: 1, quantity: 1, unit_price: 1 } ]))

      expect(response).to have_http_status(:created)
      expect(json["number"]).not_to eq("HACK-1")
      expect(json["items"].first).to include("unit_price" => 8990)
    end

    it "returns 422 with the errors by field" do
      post_order(payload.merge(delivery_address: nil, items: [ { product_id: 1, quantity: 2.5 } ]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"]).to contain_exactly(
        { "field" => "items[0].quantity", "code" => "invalid_quantity", "message" => "must be an integer between 1 and 99" }
      )
    end

    it "returns 422 when the total sent does not match" do
      post_order(payload.merge(total_amount: 100))

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].first).to include("field" => "total_amount", "code" => "total_mismatch")
    end

    it "returns 422 for unknown restaurants and products" do
      post_order(payload.merge(restaurant_id: 99, items: [ { product_id: 999, quantity: 1 } ]))

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].map { |error| error.values_at("field", "code") })
        .to contain_exactly([ "restaurant_id", "not_found" ], [ "items[0].product_id", "not_found" ])
    end

    describe "values with the wrong shape" do
      # Strong params alone would drop these values silently and accept the
      # order without them; they must reject the whole request instead.
      {
        "an item that is not an object" => [ { items: [ 17, { product_id: 1, quantity: 1 } ] }, "items[0]" ],
        "a total sent as an array" => [ { total_amount: [ 22_470 ] }, "total_amount" ],
        "a total sent as an object" => [ { total_amount: { value: 22_470 } }, "total_amount" ],
        "a restaurant id sent as an array" => [ { restaurant_id: [ 2 ] }, "restaurant_id" ],
        "an order type sent as an array" => [ { order_type: [ "delivery" ] }, "order_type" ],
        "a customer sent as a string" => [ { customer: "Ana Pérez" }, "customer" ],
        "items sent as a string" => [ { items: "1,5" }, "items" ],
        "a product id sent as an object" => [ { items: [ { product_id: { id: 1 }, quantity: 1 } ] }, "items[0].product_id" ],
        "a quantity sent as an array" => [ { items: [ { product_id: 1, quantity: [ 2 ] } ] }, "items[0].quantity" ]
      }.each do |description, (overrides, field)|
        it "rejects #{description}" do
          expect { post_order(payload.merge(overrides)) }.not_to change(Order, :count)

          expect(response).to have_http_status(:unprocessable_content)
          expect(json["errors"].map { |error| error["field"] }).to include(field)
        end
      end

      it "reports the position of the item as it was sent" do
        post_order(payload.merge(items: [ { product_id: 1, quantity: 1 }, "x", { product_id: 999, quantity: 1 } ]))

        expect(json["errors"].map { |error| error["field"] }).to eq([ "items[1]" ])
      end
    end

    it "returns 400 when the body is empty" do
      post_order({})

      expect(response).to have_http_status(:bad_request)
    end

    [ "oops", 1, true, [ 1 ], nil ].each do |root|
      it "returns 400 when order is #{root.inspect} instead of an object" do
        post api_v1_orders_path, params: { order: root }.to_json, headers: { "CONTENT_TYPE" => "application/json" }

        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  describe "GET /api/v1/orders/:id" do
    it "returns the order" do
      post_order
      id = json["id"]

      get api_v1_order_path(id), as: :json

      expect(response).to have_http_status(:ok)
      expect(json).to include("id" => id, "total_amount" => 22_470)
    end

    it "returns 404 for unknown orders" do
      get api_v1_order_path(0), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
