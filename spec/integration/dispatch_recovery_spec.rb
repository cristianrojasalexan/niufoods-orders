require "rails_helper"

# An order saved while Redis was down is delivered once the recovery runs.
RSpec.describe "Recovery of an order saved while Redis was down", type: :request do
  let!(:restaurant) do
    create(:restaurant, id: 2, code: "LCON", dispatch_url: "http://www.example.com/simulated_stores/LCON/orders")
  end
  let!(:product) { create(:product, id: 1, price: 8990) }

  before { stub_request(:post, restaurant.dispatch_url).to_rack(Rails.application) }

  it "dispatches it after the grace period" do
    allow(DispatchOrderJob).to receive(:perform_async).and_raise(RedisClient::CannotConnectError)
    post api_v1_orders_path, as: :json, params: {
      restaurant_id: 2, order_type: "pickup", customer: { name: "Ana Pérez", phone: "+56912345678" },
      items: [ { product_id: 1, quantity: 1 } ]
    }
    order = Order.find(response.parsed_body["id"])
    expect(response).to have_http_status(:created)
    expect(DispatchOrderJob.jobs).to be_empty

    # Redis is back; the grace period for a scheduled job has passed.
    order.update_columns(next_dispatch_at: 1.minute.ago)
    Orders::DispatchRecovery.call
    DispatchOrderJob.drain

    expect(order.reload).to be_dispatch_dispatched
    expect(StoreSimulator::Request.sole.idempotency_key).to eq(order.number)
  end
end
