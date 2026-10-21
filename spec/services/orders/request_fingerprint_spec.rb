require "rails_helper"

RSpec.describe Orders::RequestFingerprint do
  let(:payload) do
    {
      "restaurant_id" => 2,
      "order_type" => "delivery",
      "customer" => { "name" => "Ana Pérez", "phone" => "+56912345678" },
      "delivery_address" => "Av. Providencia 1234, Santiago"
    }
  end
  let(:items) { { 1 => 2, 5 => 1 } }

  def fingerprint(payload_changes = {}, items_override = items)
    described_class.call(payload.merge(payload_changes), items_override)
  end

  it "is a SHA-256 hex digest" do
    expect(fingerprint).to match(/\A\h{64}\z/)
  end

  describe "is the same for requests that describe the same order" do
    it "with the items in another order" do
      expect(fingerprint({}, { 5 => 1, 1 => 2 })).to eq(fingerprint)
    end

    it "with spaces around the texts" do
      changes = { "customer" => { "name" => "  Ana Pérez ", "phone" => "+56912345678" },
                  "delivery_address" => " Av. Providencia 1234, Santiago " }

      expect(fingerprint(changes)).to eq(fingerprint)
    end

    it "with the phone written with separators" do
      expect(fingerprint("customer" => { "name" => "Ana Pérez", "phone" => "+56 9 1234-5678" })).to eq(fingerprint)
    end

    it "with or without total_amount" do
      expect(fingerprint("total_amount" => 22_470)).to eq(fingerprint)
    end

    it "with an address sent for a pickup order" do
      pickup = fingerprint("order_type" => "pickup", "delivery_address" => nil)

      expect(fingerprint("order_type" => "pickup", "delivery_address" => "Somewhere 1")).to eq(pickup)
    end
  end

  describe "differs when the order changes" do
    {
      "the restaurant" => { "restaurant_id" => 3 },
      "the order type" => { "order_type" => "pickup" },
      "the customer" => { "customer" => { "name" => "Otra Persona", "phone" => "+56912345678" } },
      "the address" => { "delivery_address" => "Irarrázaval 500, Ñuñoa" }
    }.each do |what, changes|
      it "in #{what}" do
        expect(fingerprint(changes)).not_to eq(fingerprint)
      end
    end

    it "in a quantity" do
      expect(fingerprint({}, { 1 => 3, 5 => 1 })).not_to eq(fingerprint)
    end

    it "in the products" do
      expect(fingerprint({}, { 1 => 2, 6 => 1 })).not_to eq(fingerprint)
    end
  end
end
