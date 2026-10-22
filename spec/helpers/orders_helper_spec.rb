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

  describe "#relative_time" do
    let(:now) { Time.zone.local(2026, 10, 22, 12, 0, 0) }

    it "says how long ago it was" do
      expect(helper.relative_time(now - 12.seconds, now: now)).to eq("hace 12 s")
      expect(helper.relative_time(now - 3.minutes, now: now)).to eq("hace 3 min")
      expect(helper.relative_time(now - 172.seconds, now: now)).to eq("hace 2 min")
      expect(helper.relative_time(now - 5.hours, now: now)).to eq("hace 5 h")
      expect(helper.relative_time(now - 2.days, now: now)).to eq("hace 2 d")
    end

    it "never goes negative when clocks differ slightly" do
      expect(helper.relative_time(now + 2.seconds, now: now)).to eq("hace 0 s")
    end
  end

  it "labels durations shortly" do
    expect([ 4, 59.6, 125, 180, 7200 ].map { |seconds| helper.duration_label(seconds) })
      .to eq([ "4 s", "1 min", "2 min 5 s", "3 min", "2 h" ])
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
