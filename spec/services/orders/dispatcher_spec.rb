require "rails_helper"

RSpec.describe Orders::Dispatcher do
  let(:restaurant) { create(:restaurant, code: "LCON", dispatch_url: "http://stores.test/LCON/orders") }
  let(:order) { create(:order, restaurant: restaurant) }
  let(:max_attempts) { Rails.configuration.x.dispatch.max_attempts_per_cycle }

  def dispatch
    described_class.call(order.id)
  end

  def stub_store(**response)
    stub_request(:post, restaurant.dispatch_url).to_return(status: 201, body: "{}", **response)
  end

  describe "a successful delivery" do
    before { stub_store(status: 201) }

    it "marks the order as dispatched and releases the lease" do
      expect(dispatch).to eq(:success)

      expect(order.reload).to have_attributes(
        dispatch_status: "dispatched", dispatch_attempts_count: 1, dispatched_at: be_present,
        dispatch_token: nil, dispatch_lease_expires_at: nil, last_dispatch_error: nil
      )
    end

    it "posts the order as JSON with its number as Idempotency-Key" do
      dispatch

      expect(
        a_request(:post, restaurant.dispatch_url).with(headers: { "Idempotency-Key" => order.number,
                                                                 "Content-Type" => "application/json" }) do |request|
          JSON.parse(request.body).values_at("number", "total_amount") == [ order.number, order.total_amount ]
        end
      ).to have_been_made.once
    end

    it "records the attempt" do
      dispatch

      expect(order.dispatch_attempts.sole).to have_attributes(
        outcome: "success", http_status: 201, dispatch_cycle: 1, attempt_number: 1,
        dispatch_token: be_present, duration_ms: be >= 0, error_message: nil
      )
    end
  end

  describe "classification of failures" do
    {
      500 => "transient", 502 => "transient", 503 => "transient",
      408 => "transient", 425 => "transient", 429 => "transient",
      400 => "permanent", 404 => "permanent", 422 => "permanent", 301 => "permanent"
    }.each do |status, outcome|
      it "treats #{status} as #{outcome}" do
        stub_store(status: status)

        expect(dispatch).to eq(outcome.to_sym)
        expect(order.dispatch_attempts.sole).to have_attributes(outcome: outcome, http_status: status,
                                                                error_message: "store answered #{status}")
      end
    end

    it "treats a store that does not answer in time as transient" do
      stub_request(:post, restaurant.dispatch_url).to_raise(Net::ReadTimeout)

      expect(dispatch).to eq(:transient)
      expect(order.dispatch_attempts.sole).to have_attributes(http_status: nil, error_message: /TimeoutError/)
    end

    # Each read finishes before the read timeout, so only a deadline for the
    # whole request stops a store that keeps the answer trickling in.
    it "gives up as transient when the whole delivery outlasts the timeouts added" do
      settings = Rails.configuration.x.dispatch.dup.tap { |s| s.delivery_deadline_seconds = 0.1 }
      stub_request(:post, restaurant.dispatch_url).to_return do
        sleep 0.5
        { status: 201 }
      end

      expect(described_class.new(order.id, settings: settings).call).to eq(:transient)
      expect(order.dispatch_attempts.sole).to have_attributes(
        http_status: nil, error_message: "deadline exceeded: no complete answer within 0.1s",
        duration_ms: be < 400
      )
      expect(order.reload.dispatch_status).to eq("pending")
    end

    it "does not count building the order payload against the delivery deadline" do
      settings = Rails.configuration.x.dispatch.dup.tap { |s| s.delivery_deadline_seconds = 0.1 }
      allow_any_instance_of(OrderSerializer).to receive(:as_json).and_wrap_original do |original, *args|
        sleep 0.3
        original.call(*args)
      end
      stub_store(status: 201)

      expect(described_class.new(order.id, settings: settings).call).to eq(:success)
    end

    it "treats a connection that cannot be opened in time as transient" do
      stub_request(:post, restaurant.dispatch_url).to_timeout

      expect(dispatch).to eq(:transient)
      expect(order.dispatch_attempts.sole).to have_attributes(http_status: nil, error_message: /ConnectionFailed/)
    end

    it "treats a refused connection as transient" do
      stub_request(:post, restaurant.dispatch_url).to_raise(Errno::ECONNREFUSED)

      expect(dispatch).to eq(:transient)
      expect(order.dispatch_attempts.sole.error_message).to match(/ConnectionFailed/)
    end

    it "marks the order as failed with the error" do
      stub_store(status: 422)
      dispatch

      expect(order.reload).to have_attributes(dispatch_status: "failed", last_dispatch_error: "store answered 422",
                                              dispatch_token: nil, dispatch_lease_expires_at: nil)
    end
  end

  describe "a transient failure" do
    let(:base) { Rails.configuration.x.dispatch.retry_base_seconds }

    it "puts the order back to pending with the time of its next attempt" do
      stub_store(status: 503)

      expect(dispatch).to eq(:transient)

      order.reload
      expect(order).to have_attributes(dispatch_status: "pending", dispatch_token: nil,
                                       dispatch_lease_expires_at: nil, last_dispatch_error: "store answered 503")
      expect(order.next_dispatch_at).to be_within(2.seconds).of(base.seconds.from_now)
    end

    it "schedules the next attempt for that time" do
      stub_store(status: 503)
      dispatch

      job = DispatchOrderJob.jobs.sole
      expect(job["args"]).to eq([ order.id ])
      expect(Time.at(job["at"])).to be_within(2.seconds).of(base.seconds.from_now)
    end

    it "waits longer after each failed attempt" do
      stub_store(status: 503)
      order.update_columns(dispatch_attempts_count: 2)

      dispatch

      expect(order.reload.next_dispatch_at).to be_within(2.seconds).of((4 * base).seconds.from_now)
    end

    it "waits what the store asks for with Retry-After" do
      stub_store(status: 429, headers: { "Retry-After" => "120" })
      dispatch

      expect(order.reload.next_dispatch_at).to be_within(2.seconds).of(120.seconds.from_now)
    end

    it "marks the order as failed after the last attempt of the cycle" do
      stub_store(status: 503)
      order.update_columns(dispatch_attempts_count: max_attempts - 1)

      dispatch

      expect(order.reload).to have_attributes(
        dispatch_status: "failed", dispatch_attempts_count: max_attempts,
        last_dispatch_error: "store answered 503 (gave up after #{max_attempts} attempts)"
      )
      expect(DispatchOrderJob.jobs).to be_empty
    end

    it "is not retried when the failure is permanent" do
      stub_store(status: 422)
      dispatch

      expect(order.reload).to be_dispatch_failed
      expect(DispatchOrderJob.jobs).to be_empty
    end

    it "is not retried by a worker that lost its lease" do
      stub_request(:post, restaurant.dispatch_url).to_return do
        order.update_columns(dispatch_token: SecureRandom.uuid, dispatch_lease_expires_at: 1.minute.from_now)
        { status: 503 }
      end

      expect(dispatch).to eq(:stale)
      expect(DispatchOrderJob.jobs).to be_empty
    end

    it "keeps the order pending for the recovery when the retry cannot be scheduled" do
      stub_store(status: 503)
      allow(DispatchOrderJob).to receive(:perform_in).and_raise(RedisClient::CannotConnectError)

      expect(dispatch).to eq(:transient)
      expect(order.reload).to be_dispatch_pending
    end
  end

  describe "claim" do
    before { stub_store(status: 201) }

    def expect_skipped
      expect(dispatch).to eq(:skipped)
      expect(a_request(:post, restaurant.dispatch_url)).not_to have_been_made
      expect(order.dispatch_attempts).to be_empty
    end

    it "skips an order that is not due yet" do
      order.update_columns(next_dispatch_at: 1.minute.from_now)

      expect_skipped
    end

    it "skips an order that was already dispatched" do
      dispatch
      WebMock.reset_executed_requests!

      expect(dispatch).to eq(:skipped)
      expect(a_request(:post, restaurant.dispatch_url)).not_to have_been_made
    end

    it "skips an order held by another worker" do
      order.update_columns(dispatch_status: "dispatching", dispatch_token: SecureRandom.uuid,
                           dispatch_lease_expires_at: 30.seconds.from_now)

      expect_skipped
    end

    it "takes over an order whose lease expired" do
      order.update_columns(dispatch_status: "dispatching", dispatch_token: SecureRandom.uuid,
                           dispatch_lease_expires_at: 1.second.ago, dispatch_attempts_count: 1)

      expect(dispatch).to eq(:success)
      expect(order.reload).to have_attributes(dispatch_status: "dispatched", dispatch_attempts_count: 2)
    end

    it "does not claim an order without attempts left, even with an expired lease" do
      order.update_columns(dispatch_status: "dispatching", dispatch_token: SecureRandom.uuid,
                           dispatch_lease_expires_at: 1.second.ago, dispatch_attempts_count: max_attempts)

      expect_skipped
    end

    it "skips orders that do not exist" do
      expect(described_class.call(0)).to eq(:skipped)
    end
  end

  describe "a worker that is suspended right after its claim" do
    # Between the claim and the rest of its work, the lease of the first
    # worker expires and a second worker takes the order over and delivers
    # it. The first one must still record its own attempt number.
    before do
      stub_store(status: 201)
      taken_over = false
      allow(Order).to receive(:includes).and_wrap_original do |original, *args|
        unless taken_over
          taken_over = true
          Order.where(id: order.id).update_all(dispatch_lease_expires_at: 1.second.ago)
          described_class.call(order.id)
        end
        original.call(*args)
      end
    end

    it "records each attempt with the number its own claim got" do
      dispatch

      expect(order.dispatch_attempts.map { |attempt| [ attempt.attempt_number, attempt.outcome ] })
        .to contain_exactly([ 2, "success" ], [ 1, "stale" ])
    end
  end

  describe "a worker that loses its lease during the delivery" do
    # While the request is in flight, the lease expires and another worker
    # takes over the order with its own token.
    before do
      stub_request(:post, restaurant.dispatch_url).to_return do
        order.update_columns(dispatch_token: SecureRandom.uuid, dispatch_lease_expires_at: 1.minute.from_now)
        { status: 201, body: "{}" }
      end
    end

    it "does not overwrite the order" do
      expect(dispatch).to eq(:stale)

      expect(order.reload).to have_attributes(dispatch_status: "dispatching", dispatched_at: nil)
    end

    it "records the attempt as stale" do
      dispatch

      expect(order.dispatch_attempts.sole).to have_attributes(outcome: "stale", http_status: 201,
                                                              error_message: /lease lost.*\(success\)/)
    end
  end
end
