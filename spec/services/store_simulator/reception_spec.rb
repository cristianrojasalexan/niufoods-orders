require "rails_helper"

RSpec.describe StoreSimulator::Reception do
  let(:payload) { { "number" => "LCON-000042", "total_amount" => 22_470 } }

  def deliver(key = "LCON-000042", store: "LCON")
    described_class.call(store_code: store, idempotency_key: key, payload: payload)
  end

  def request_for(key = "LCON-000042", store: "LCON")
    StoreSimulator::Request.find_by(store_code: store, idempotency_key: key)
  end

  before { StoreSimulator::Mode.change!("LCON", mode) }

  context "when the store is ok" do
    let(:mode) { "ok" }

    it "receives the order and stores the payload" do
      result = deliver

      expect(result).to have_attributes(status: :received, attempts: 1, http_status: :created)
      expect(request_for).to have_attributes(attempts: 1, payload: payload, received_at: be_present)
    end

    it "answers a second delivery of the same order as a duplicate without receiving it again" do
      deliver
      received_at = request_for.received_at

      expect(deliver).to have_attributes(status: :duplicate, attempts: 2, http_status: :ok)
      expect(request_for.received_at).to eq(received_at)
    end

    it "keeps orders of different stores apart" do
      StoreSimulator::Mode.change!("PROV", "ok")
      deliver("SAME-KEY")

      expect(deliver("SAME-KEY", store: "PROV").status).to eq(:received)
    end
  end

  context "when the store is flaky" do
    let(:mode) { "flaky:2" }

    it "fails the first attempts of each order and then receives it" do
      statuses = Array.new(3) { deliver.status }

      expect(statuses).to eq(%i[unavailable unavailable received])
      expect(request_for.attempts).to eq(3)
    end

    it "counts attempts per order" do
      2.times { deliver("A") }

      expect(deliver("B").status).to eq(:unavailable)
      expect(deliver("A").status).to eq(:received)
    end
  end

  context "when the store rejects orders" do
    let(:mode) { "reject" }

    it "answers 422 and never records the order as received" do
      expect(deliver).to have_attributes(status: :rejected, http_status: :unprocessable_content)
      expect(request_for).to have_attributes(attempts: 1, received_at: nil, payload: nil)
    end
  end

  context "when the store is down" do
    let(:mode) { "down" }

    it "answers 503 and never records the order as received" do
      2.times { deliver }

      expect(deliver).to have_attributes(status: :unavailable, attempts: 3, http_status: :service_unavailable)
      expect(request_for.received_at).to be_nil
    end

    it "receives the order once the store is back" do
      deliver
      StoreSimulator::Mode.change!("LCON", "ok")

      expect(deliver.status).to eq(:received)
    end
  end
end
