require "rails_helper"

RSpec.describe Orders::DispatchRecovery do
  let(:settings) { Rails.configuration.x.dispatch }
  let(:max_attempts) { settings.max_attempts_per_cycle }
  let(:grace) { settings.recovery_grace_seconds }

  def recover
    described_class.call
  end

  def enqueued_ids
    DispatchOrderJob.jobs.map { |job| job["args"].first }
  end

  def order_in(state, **columns)
    create(:order).tap { |order| order.update_columns(dispatch_status: state, **columns) }
  end

  def holding(lease_expires_at:, attempts:)
    order_in("dispatching", dispatch_token: SecureRandom.uuid, dispatch_lease_expires_at: lease_expires_at,
                            dispatch_attempts_count: attempts)
  end

  describe "pending orders" do
    it "enqueues an order that is past its next attempt by more than the grace period" do
      order = order_in("pending", next_dispatch_at: (grace + 5).seconds.ago)

      expect(recover).to have_attributes(enqueued: 1, failed: 0)
      expect(enqueued_ids).to eq([ order.id ])
    end

    it "leaves an order whose scheduled job may still be about to run" do
      order_in("pending", next_dispatch_at: (grace - 5).seconds.ago)

      expect(recover.enqueued).to eq(0)
    end

    it "leaves an order whose next attempt is still ahead" do
      order_in("pending", next_dispatch_at: 1.minute.from_now)

      expect(recover.enqueued).to eq(0)
    end
  end

  describe "expired leases" do
    it "enqueues an order whose worker died while attempts are left" do
      order = holding(lease_expires_at: 1.second.ago, attempts: max_attempts - 1)

      recover

      expect(enqueued_ids).to eq([ order.id ])
      expect(order.reload).to be_dispatch_dispatching
    end

    it "leaves an order whose worker still holds a valid lease" do
      holding(lease_expires_at: 30.seconds.from_now, attempts: 1)

      expect(recover).to have_attributes(enqueued: 0, failed: 0)
    end

    it "fails an order whose lease expired during the last attempt, clearing its token" do
      order = holding(lease_expires_at: 1.second.ago, attempts: max_attempts)

      expect(recover).to have_attributes(enqueued: 0, failed: 1)
      expect(order.reload).to have_attributes(
        dispatch_status: "failed", dispatch_token: nil, dispatch_lease_expires_at: nil,
        last_dispatch_error: "lease expired during the last attempt (#{max_attempts}); delivery result unknown"
      )
    end
  end

  describe "pending orders without attempts left" do
    # MAX_ATTEMPTS_PER_CYCLE was lowered while these orders had already used
    # more attempts than the new limit, so no claim will ever take them.
    before { stub_const("#{described_class}::BATCH_SIZE", 2) }

    let!(:exhausted) do
      Array.new(3) { |index| order_in("pending", next_dispatch_at: (10 - index).minutes.ago, dispatch_attempts_count: max_attempts + 1) }
    end
    let!(:recoverable) { order_in("pending", next_dispatch_at: 1.minute.ago, dispatch_attempts_count: 1) }

    it "does not let them fill the batch and block other orders" do
      2.times { recover }

      expect(enqueued_ids.uniq).to eq([ recoverable.id ])
    end

    it "fails them, since no attempt can be made" do
      expect(recover.failed).to eq(3)

      exhausted.each do |order|
        expect(order.reload).to have_attributes(
          dispatch_status: "failed",
          last_dispatch_error: "no attempts left in the cycle (#{max_attempts + 1} of #{max_attempts}); the limit was lowered"
        )
      end
    end
  end

  it "does not touch dispatched or failed orders" do
    order_in("dispatched", dispatched_at: 1.hour.ago, next_dispatch_at: 1.hour.ago)
    order_in("failed", next_dispatch_at: 1.hour.ago)

    expect(recover).to have_attributes(enqueued: 0, failed: 0)
  end

  it "enqueues the oldest orders first" do
    newer = order_in("pending", next_dispatch_at: 2.minutes.ago)
    older = order_in("pending", next_dispatch_at: 5.minutes.ago)

    recover

    expect(enqueued_ids).to eq([ older.id, newer.id ])
  end

  it "is safe to run again" do
    order_in("pending", next_dispatch_at: 5.minutes.ago)
    holding(lease_expires_at: 1.second.ago, attempts: max_attempts)

    recover
    second = recover

    expect(second.failed).to eq(0)
    expect(DispatchOrderJob.jobs.size).to eq(2)
  end

  it "lets the claim discard a job enqueued for an order that is not due" do
    order = order_in("pending", next_dispatch_at: 1.minute.from_now)
    DispatchOrderJob.perform_async(order.id)

    DispatchOrderJob.drain

    expect(order.reload).to have_attributes(dispatch_status: "pending", dispatch_attempts_count: 0)
  end

  describe "a worker that finishes after the recovery failed its order" do
    let(:restaurant) { create(:restaurant, dispatch_url: "http://stores.test/LATE/orders") }
    let(:order) { create(:order, restaurant: restaurant) }

    it "has its late result discarded as stale" do
      order.update_columns(dispatch_attempts_count: max_attempts - 1)
      # The worker claims the last attempt; while its request is in flight,
      # its lease expires and the recovery fails the order.
      stub_request(:post, restaurant.dispatch_url).to_return do
        order.update_columns(dispatch_lease_expires_at: 1.second.ago)
        recover
        { status: 201, body: "{}" }
      end

      expect(Orders::Dispatcher.call(order.id)).to eq(:stale)

      expect(order.reload).to have_attributes(dispatch_status: "failed", dispatched_at: nil)
      expect(order.dispatch_attempts.sole).to have_attributes(attempt_number: max_attempts, outcome: "stale")
    end
  end
end
