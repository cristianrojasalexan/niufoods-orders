require "rails_helper"

# Real concurrent changes of a store that has no saved mode yet, each with
# its own database connection, so this spec manages its own records.
RSpec.describe StoreSimulator::Mode, "with concurrent changes" do
  self.use_transactional_tests = false

  # The pool has 5 connections and the main thread keeps one.
  let(:modes) { %w[down reject flaky:2 ok] }

  after { described_class.delete_all }

  it "applies every first change of the same store without failing" do
    barrier = Concurrent::CyclicBarrier.new(modes.size)

    results = modes.map do |mode|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait(5) || raise("not every change started")
          described_class.change!("RACE", mode)
          :ok
        rescue StandardError => e
          e.class
        end
      end
    end.map(&:value)

    expect(results).to all(eq(:ok))
    expect(described_class.where(store_code: "RACE").count).to eq(1)
    expect(modes).to include(described_class.current("RACE"))
  end
end
