require "rails_helper"

RSpec.describe OrdersHelper do
  describe "#clp" do
    it "formats Chilean pesos without decimals and with dots" do
      expect(helper.clp(22_470)).to eq("$ 22.470")
      expect(helper.clp(1_146_940)).to eq("$ 1.146.940")
      expect(helper.clp(0)).to eq("$ 0")
    end
  end

  it "labels the order types" do
    expect(helper.order_type_label(build(:order, order_type: "pickup"))).to eq("Retiro")
    expect(helper.order_type_label(build(:order, order_type: "delivery"))).to eq("Delivery")
  end

  it "labels every dispatch status" do
    expect(Order.dispatch_statuses.keys.map { |status| helper.dispatch_status_label(status) })
      .to eq(%w[Pendiente Enviando Enviada Error])
  end
end
