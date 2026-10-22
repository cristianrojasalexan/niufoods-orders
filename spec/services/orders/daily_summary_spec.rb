require "rails_helper"

RSpec.describe Orders::DailySummary do
  def order_created(at:, status: "pending", dispatched_after: nil)
    create(:order).tap do |order|
      columns = { created_at: at, dispatch_status: status }
      columns[:dispatched_at] = at + dispatched_after if dispatched_after
      order.update_columns(columns)
    end
  end

  let(:today) { Time.zone.local(2026, 10, 22, 12, 0, 0) }

  it "sums the orders of the day and how their dispatch went" do
    delivered = order_created(at: today - 2.hours, status: "dispatched", dispatched_after: 2.seconds)
    order_created(at: today - 1.hour, status: "dispatched", dispatched_after: 4.seconds)
    order_created(at: today - 30.minutes, status: "failed")
    order_created(at: today - 5.minutes)
    order_created(at: today - 1.day, status: "dispatched", dispatched_after: 60.seconds)

    summary = described_class.call(day: today.to_date)

    expect(summary).to have_attributes(orders: 4, dispatched: 2, failed: 1, average_delivery_seconds: 3.0)
    expect(summary.amount).to eq(4 * delivered.total_amount)
    expect(summary.delivery_rate).to be_within(0.001).of(2.0 / 3)
  end

  it "uses the day of the app time zone" do
    order_created(at: Time.zone.local(2026, 10, 22, 0, 30))

    expect(described_class.call(day: Date.new(2026, 10, 22)).orders).to eq(1)
    expect(described_class.call(day: Date.new(2026, 10, 21)).orders).to eq(0)
  end

  it "has no rate or average before any dispatch ended" do
    order_created(at: today)

    summary = described_class.call(day: today.to_date)

    expect(summary).to have_attributes(orders: 1, delivery_rate: nil, average_delivery_seconds: nil)
  end
end
