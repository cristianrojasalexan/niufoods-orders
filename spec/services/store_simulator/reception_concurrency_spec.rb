require "rails_helper"

# Real concurrent deliveries of the same order, each with its own database
# connection, so this spec manages its own records.
RSpec.describe StoreSimulator::Reception, "with concurrent deliveries" do
  self.use_transactional_tests = false

  # The pool has 5 connections and the main thread keeps one.
  let(:threads) { 4 }
  let(:key) { "LCON-#{SecureRandom.hex(4)}" }

  before { StoreSimulator::Mode.change!("LCON", "ok") }

  after do
    StoreSimulator::Request.delete_all
    StoreSimulator::Mode.delete_all
  end

  def deliver_concurrently
    Array.new(threads) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(store_code: "LCON", idempotency_key: key, payload: { "delivery" => index })
        end
      end
    end.map(&:value)
  end

  it "receives the order exactly once" do
    # Every delivery counts its attempt and sees the order as not received
    # before any of them marks it, so they all compete for the reception.
    barrier = Concurrent::CyclicBarrier.new(threads)
    allow_any_instance_of(described_class).to receive(:answer).and_wrap_original do |original, *args|
      barrier.wait(5) || raise("not every delivery reached the reception")
      original.call(*args)
    end

    results = deliver_concurrently

    request = StoreSimulator::Request.find_by(store_code: "LCON", idempotency_key: key)
    expect(results.map(&:status).tally).to eq(received: 1, duplicate: threads - 1)
    expect(request.attempts).to eq(threads)
    expect(request.payload).to eq("delivery" => results.index { |result| result.status == :received })
  end

  it "receives the order exactly once when deliveries race without coordination" do
    results = deliver_concurrently

    expect(results.count { |result| result.status == :received }).to eq(1)
    expect(StoreSimulator::Request.where(idempotency_key: key).count).to eq(1)
  end
end
