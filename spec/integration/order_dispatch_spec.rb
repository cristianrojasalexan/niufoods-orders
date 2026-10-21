require "rails_helper"

# End to end in one process: the order enters through the API, the job
# delivers it and the simulated store served by this same app receives it.
RSpec.describe "Order dispatch to the simulated store", type: :request do
  let!(:restaurant) do
    create(:restaurant, id: 2, code: "LCON", dispatch_url: "http://www.example.com/simulated_stores/LCON/orders")
  end
  let!(:product) { create(:product, id: 1, price: 8990) }

  # Route the dispatch to the app itself instead of the network.
  before { stub_request(:post, restaurant.dispatch_url).to_rack(Rails.application) }

  def create_order
    post api_v1_orders_path, as: :json, params: {
      restaurant_id: 2, order_type: "pickup",
      customer: { name: "Ana Pérez", phone: "+56912345678" },
      items: [ { product_id: 1, quantity: 2 } ]
    }
    Order.find(response.parsed_body["id"])
  end

  it "delivers a new order to its store" do
    order = create_order
    expect(order).to be_dispatch_pending

    DispatchOrderJob.drain

    expect(order.reload).to be_dispatch_dispatched
    receipt = StoreSimulator::Request.sole
    expect(receipt).to have_attributes(store_code: "LCON", idempotency_key: order.number, received_at: be_present)
    expect(receipt.payload).to include("number" => order.number, "total_amount" => 17_980)
  end

  it "shows the dispatch state in the API" do
    order = create_order
    DispatchOrderJob.drain

    get api_v1_order_path(order)

    expect(response.parsed_body["dispatch"]).to include("status" => "dispatched", "attempts" => 1,
                                                        "dispatched_at" => be_present, "last_error" => nil)
  end

  it "marks the order as failed when the store rejects it" do
    StoreSimulator::Mode.change!("LCON", "reject")
    order = create_order

    DispatchOrderJob.drain

    expect(order.reload).to have_attributes(dispatch_status: "failed", last_dispatch_error: "store answered 422")
    expect(StoreSimulator::Request.sole.received_at).to be_nil
  end
end
