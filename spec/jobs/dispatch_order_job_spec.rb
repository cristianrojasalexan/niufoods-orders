require "rails_helper"

RSpec.describe DispatchOrderJob do
  it "runs in the dispatch queue without Sidekiq retries" do
    expect(described_class.get_sidekiq_options).to include("queue" => "dispatch", "retry" => false)
  end

  it "runs one dispatch attempt of the order" do
    allow(Orders::Dispatcher).to receive(:call).with(42).and_return(:success)

    described_class.new.perform(42)

    expect(Orders::Dispatcher).to have_received(:call).with(42)
  end

  describe ".enqueue_after_commit" do
    let(:order) { create(:order) }

    it "enqueues the dispatch of the order" do
      described_class.enqueue_after_commit(order)

      expect(described_class.jobs.map { |job| job["args"] }).to eq([ [ order.id ] ])
    end

    it "schedules it when asked to wait" do
      described_class.enqueue_after_commit(order, wait: 30)

      expect(described_class.jobs.sole["at"]).to be_within(2).of(30.seconds.from_now.to_f)
    end

    it "waits until the transaction commits" do
      Order.transaction(requires_new: true) do
        described_class.enqueue_after_commit(order)

        expect(described_class.jobs).to be_empty
      end

      expect(described_class.jobs.size).to eq(1)
    end

    it "is not enqueued if the transaction rolls back" do
      Order.transaction(requires_new: true) do
        described_class.enqueue_after_commit(order)
        raise ActiveRecord::Rollback
      end

      expect(described_class.jobs).to be_empty
    end

    it "logs a Redis failure instead of raising it, leaving the order to the recovery" do
      allow(described_class).to receive(:perform_async).and_raise(RedisClient::CannotConnectError, "Connection refused")
      allow(Rails.logger).to receive(:warn)

      expect { described_class.enqueue_after_commit(order) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/#{order.number}.*CannotConnectError.*dispatch recovery/)
    end
  end
end
