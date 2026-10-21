require "rails_helper"

RSpec.describe "Simulated stores", type: :request do
  let(:json) { response.parsed_body }
  let(:order) { { number: "LCON-000042", total_amount: 22_470, items: [ { product_id: 1, quantity: 2 } ] } }

  def deliver(body = order.to_json, key: "LCON-000042")
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["Idempotency-Key"] = key if key
    post simulated_store_orders_path("LCON"), params: body, headers: headers
  end

  describe "POST /simulated_stores/:code/orders" do
    it "receives the order as it was sent" do
      deliver

      expect(response).to have_http_status(:created)
      expect(json).to eq("store" => "LCON", "idempotency_key" => "LCON-000042", "status" => "received", "attempts" => 1)
      expect(StoreSimulator::Request.last.payload).to eq(order.deep_stringify_keys)
    end

    it "answers a repeated delivery with 200 duplicate" do
      2.times { deliver }

      expect(response).to have_http_status(:ok)
      expect(json).to include("status" => "duplicate", "attempts" => 2)
    end

    it "answers according to the mode of the store" do
      StoreSimulator::Mode.change!("LCON", "down")
      deliver

      expect(response).to have_http_status(:service_unavailable)
      expect(json["status"]).to eq("unavailable")
    end

    it "requires an Idempotency-Key" do
      deliver(key: nil)

      expect(response).to have_http_status(:bad_request)
      expect(StoreSimulator::Request.count).to eq(0)
    end

    it "requires a JSON object" do
      [ "", "[1, 2]" ].each do |body|
        deliver(body)

        expect(response).to have_http_status(:bad_request)
      end
    end

    it "rejects malformed JSON" do
      deliver('{"number":')

      expect(response).to have_http_status(:bad_request)
    end

    it "only serves store codes in uppercase" do
      post "/simulated_stores/lcon/orders", params: order.to_json, headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /simulated_stores/:code/orders" do
    it "lists what the store was asked to receive" do
      StoreSimulator::Mode.change!("LCON", "flaky:1")
      2.times { deliver }

      get simulated_store_orders_path("LCON")

      expect(json).to include("store" => "LCON", "mode" => "flaky:1")
      expect(json["orders"]).to contain_exactly(include("idempotency_key" => "LCON-000042", "attempts" => 2,
                                                        "received_at" => be_present))
    end
  end

  describe "the mode of a store" do
    it "can be read and changed" do
      get simulated_store_mode_path("NUNO")
      expect(response.parsed_body).to eq("store" => "NUNO", "mode" => "ok")

      put simulated_store_mode_path("NUNO"), params: { mode: "flaky:2" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("store" => "NUNO", "mode" => "flaky:2")
      expect(StoreSimulator::Mode.current("NUNO")).to eq("flaky:2")
    end

    it "rejects unknown modes" do
      put simulated_store_mode_path("NUNO"), params: { mode: "sometimes" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to match(/ok, reject, down or flaky:N/)
    end

    it "requires a mode" do
      put simulated_store_mode_path("NUNO"), params: {}, as: :json

      expect(response).to have_http_status(:bad_request)
    end
  end
end
