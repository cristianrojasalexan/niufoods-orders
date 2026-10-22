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

  it "labels every dispatch attempt outcome" do
    labels = DispatchAttempt.outcomes.keys.map { |outcome| helper.dispatch_outcome_badge(DispatchAttempt.new(outcome: outcome)) }

    expect(labels.map { |badge| Nokogiri::HTML.fragment(badge).text })
      .to eq([ "Entregada", "Falla transitoria", "Rechazada", "Descartado" ])
  end

  it "groups the attempts by cycle, the latest cycle first" do
    order = build(:order)
    order.dispatch_attempts.build([ { dispatch_cycle: 1, attempt_number: 1 }, { dispatch_cycle: 2, attempt_number: 1 },
                                    { dispatch_cycle: 1, attempt_number: 2 } ])

    expect(helper.attempts_by_cycle(order).map { |cycle, attempts| [ cycle, attempts.map(&:attempt_number) ] })
      .to eq([ [ 2, [ 1 ] ], [ 1, [ 1, 2 ] ] ])
  end
end
