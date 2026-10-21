require "rails_helper"
load Rails.root.join("script/simulate_orders.rb")

RSpec.describe OrderSimulation do
  let(:products) { OrderSimulation.load_dataset("products") }
  let(:restaurants) { OrderSimulation.load_dataset("restaurants") }

  def generator(seed = 1)
    OrderSimulation::Generator.new(products: products, restaurants: restaurants, random: Random.new(seed))
  end

  describe OrderSimulation::Generator do
    it "builds orders with the shape of the reference payload from the dataset" do
      payload = generator.valid_order.payload

      expect(payload.keys).to include("restaurant_id", "order_type", "customer", "items")
      expect(restaurants.map { |restaurant| restaurant["id"] }).to include(payload["restaurant_id"])
      expect(payload["customer"].keys).to eq(%w[name phone])
      expect(payload["items"]).to all(match("product_id" => be_between(1, 10), "quantity" => be_between(1, 4)))
    end

    it "covers several restaurants, both order types and one to five products" do
      orders = Array.new(60) { generator(_1).valid_order.payload }

      expect(orders.map { |order| order["restaurant_id"] }.uniq).to contain_exactly(1, 2, 3)
      expect(orders.map { |order| order["order_type"] }.uniq).to contain_exactly("pickup", "delivery")
      expect(orders.map { |order| order["items"].size }.uniq.sort).to eq([ 1, 2, 3, 4, 5 ])
    end

    it "only adds an address to delivery orders and never repeats a product" do
      Array.new(30) { generator(_1).valid_order.payload }.each do |order|
        expect(order.key?("delivery_address")).to eq(order["order_type"] == "delivery")
        expect(order["items"].map { |item| item["product_id"] }).to eq(order["items"].map { |item| item["product_id"] }.uniq)
      end
    end

    it "is repeatable with the same seed" do
      expect(generator(42).valid_order.payload).to eq(generator(42).valid_order.payload)
    end
  end

  describe "against the API" do
    before do
      expect { load Rails.root.join("db/seeds.rb") }.to output.to_stdout
      stub_request(:post, "http://simulation.test/api/v1/orders").to_rack(Rails.application)
    end

    let(:client) { OrderSimulation::Client.new("http://simulation.test") }

    it "gets every valid order created with the total of the catalog" do
      order = generator.valid_order
      response = client.create_order(order.payload)

      expect(response.status).to eq(201)
      expected_total = order.payload["items"].sum do |item|
        products.find { |product| product["id"] == item["product_id"] }["price"] * item["quantity"]
      end
      expect(response.body["total_amount"]).to eq(expected_total)
    end

    OrderSimulation::INVALID_KINDS.each do |kind, description|
      it "gets #{description} rejected with 422" do
        response = client.create_order(generator.invalid_order(kind).payload)

        expect(response.status).to eq(422)
        expect(response.body["errors"]).to be_present
      end
    end

    it "runs a whole simulation with every answer as expected" do
      out = StringIO.new
      outcomes = OrderSimulation::Run.new(count: 25, invalid_ratio: 0.3, client: client, generator: generator(7),
                                          random: Random.new(7), out: out).call

      expect(outcomes).to all(be_as_expected)
      expect(Order.count).to eq(outcomes.count { |outcome| outcome.order.valid? })
      expect(out.string).to include("Orders sent:             25", "Unexpected answers:      0")
    end
  end

  it "reports a network error instead of stopping" do
    stub_request(:post, "http://down.test/api/v1/orders").to_raise(Errno::ECONNREFUSED)

    response = OrderSimulation::Client.new("http://down.test").create_order({})

    expect(response.error).to match(/ECONNREFUSED/)
  end

  it "validates its options" do
    expect(described_class.parse_options(%w[--count 5 --invalid-ratio 0.5 --seed 3]))
      .to include(count: 5, invalid_ratio: 0.5, seed: 3)
    expect { described_class.parse_options(%w[--invalid-ratio 2]) }.to raise_error(OptionParser::InvalidArgument)
  end
end
