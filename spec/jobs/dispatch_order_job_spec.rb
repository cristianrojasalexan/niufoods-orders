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
end
