require "rails_helper"

RSpec.describe StoreSimulator::Mode do
  describe ".current" do
    it "is ok for stores without a configured mode" do
      expect(described_class.current("PROV")).to eq("ok")
    end

    it "uses STORE_MODES when nothing was saved" do
      stub_const("ENV", ENV.to_h.merge("STORE_MODES" => "PROV=ok, LCON=flaky:2,NUNO=down"))

      expect(described_class.current("LCON")).to eq("flaky:2")
      expect(described_class.current("NUNO")).to eq("down")
    end

    it "prefers the saved mode over STORE_MODES" do
      stub_const("ENV", ENV.to_h.merge("STORE_MODES" => "LCON=flaky:2"))
      described_class.change!("LCON", "reject")

      expect(described_class.current("LCON")).to eq("reject")
    end
  end

  describe ".defaults" do
    it "ignores invalid entries" do
      expect(described_class.defaults("PROV=ok,lcon=down,NUNO=sometimes,,=ok,LCON")).to eq("PROV" => "ok")
    end
  end

  describe ".change!" do
    it "creates or updates the mode of a store" do
      described_class.change!("PROV", "down")
      described_class.change!("PROV", "flaky:3")

      expect(described_class.count).to eq(1)
      expect(described_class.current("PROV")).to eq("flaky:3")
    end

    it "rejects unknown modes" do
      expect { described_class.change!("PROV", "sometimes") }.to raise_error(ActiveRecord::RecordInvalid, /ok, reject, down or flaky:N/)
    end
  end
end
