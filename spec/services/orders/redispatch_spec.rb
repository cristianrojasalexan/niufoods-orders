require "rails_helper"

RSpec.describe Orders::Redispatch do
  def order_in(state, **columns)
    create(:order).tap { |order| order.update_columns(dispatch_status: state, **columns) }
  end

  def failed_order
    order_in("failed", dispatch_cycle: 1, dispatch_attempts_count: 5, next_dispatch_at: 1.hour.ago,
                       last_dispatch_error: "store answered 503 (gave up after 5 attempts)")
  end

  describe "a failed order" do
    it "opens a new cycle with its attempts back at 0, due now" do
      order = failed_order

      expect(described_class.call(order, cycle: 1)).to eq(2)

      expect(order.reload).to have_attributes(dispatch_status: "pending", dispatch_cycle: 2, dispatch_attempts_count: 0,
                                              dispatch_token: nil, dispatch_lease_expires_at: nil)
      expect(order.next_dispatch_at).to be_within(5.seconds).of(Time.current)
    end

    it "enqueues its dispatch" do
      order = failed_order

      described_class.call(order, cycle: 1)

      expect(DispatchOrderJob.jobs.map { |job| job["args"] }).to eq([ [ order.id ] ])
    end

    it "keeps the attempts of the previous cycle" do
      order = failed_order
      order.dispatch_attempts.create!(dispatch_cycle: 1, attempt_number: 1, dispatch_token: SecureRandom.uuid,
                                      outcome: "permanent", http_status: 422, duration_ms: 12)

      described_class.call(order, cycle: 1)

      expect(order.dispatch_attempts.reload.map(&:dispatch_cycle)).to eq([ 1 ])
    end

    it "can be claimed again by the dispatcher" do
      order = failed_order
      described_class.call(order, cycle: 1)
      stub_request(:post, order.restaurant.dispatch_url).to_return(status: 201)

      expect(Orders::Dispatcher.call(order.id)).to eq(:success)
      expect(order.dispatch_attempts.reload.last).to have_attributes(dispatch_cycle: 2, attempt_number: 1)
    end
  end

  describe "an order that is not failed" do
    it "does not change a pending order or enqueue it" do
      order = order_in("pending", dispatch_attempts_count: 2)

      expect(described_class.call(order, cycle: 1)).to be_nil
      expect(order.reload).to have_attributes(dispatch_status: "pending", dispatch_cycle: 1, dispatch_attempts_count: 2)
      expect(DispatchOrderJob.jobs).to be_empty
    end

    it "does not take an order away from the worker sending it" do
      token = SecureRandom.uuid
      order = order_in("dispatching", dispatch_token: token, dispatch_lease_expires_at: 1.minute.from_now,
                                      dispatch_attempts_count: 1)

      expect(described_class.call(order, cycle: 1)).to be_nil
      expect(order.reload).to have_attributes(dispatch_status: "dispatching", dispatch_token: token)
    end

    it "does not send a delivered order again" do
      order = order_in("dispatched", dispatched_at: Time.current)

      expect(described_class.call(order, cycle: 1)).to be_nil
      expect(order.reload.dispatch_status).to eq("dispatched")
    end
  end

  describe "retrying the same failure twice" do
    it "only reopens the order once" do
      order = failed_order

      expect([ described_class.call(order, cycle: 1), described_class.call(order, cycle: 1) ]).to eq([ 2, nil ])
      expect(order.reload.dispatch_cycle).to eq(2)
      expect(DispatchOrderJob.jobs.size).to eq(1)
    end

    # The second click was sent from a page that still showed cycle 1, but
    # the store rejected the new cycle before it arrived.
    it "does not open another cycle when the new one already failed" do
      order = failed_order
      stub_request(:post, order.restaurant.dispatch_url).to_return(status: 422)

      described_class.call(order, cycle: 1)
      Orders::Dispatcher.call(order.id)
      expect(order.reload).to have_attributes(dispatch_status: "failed", dispatch_cycle: 2)

      expect(described_class.call(order, cycle: 1)).to be_nil
      expect(order.reload).to have_attributes(dispatch_status: "failed", dispatch_cycle: 2, dispatch_attempts_count: 1)
      expect(DispatchOrderJob.jobs.size).to eq(1)
    end

    it "reopens the new cycle when it is the one retried" do
      order = failed_order
      described_class.call(order, cycle: 1)
      order.update_columns(dispatch_status: "failed", dispatch_attempts_count: 5)

      expect(described_class.call(order, cycle: 2)).to eq(3)
    end
  end

  it "does nothing without a valid cycle" do
    order = failed_order

    expect(described_class.call(order, cycle: nil)).to be_nil
    expect(order.reload.dispatch_status).to eq("failed")
  end

  context "when Redis is not available" do
    before { allow(DispatchOrderJob).to receive(:perform_async).and_raise(RedisClient::CannotConnectError) }

    it "still reopens the order, pending and due for the dispatch recovery" do
      order = failed_order

      expect(described_class.call(order, cycle: 1)).to eq(2)
      expect(order.reload).to have_attributes(dispatch_status: "pending", dispatch_attempts_count: 0)
    end
  end
end
