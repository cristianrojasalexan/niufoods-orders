require "rails_helper"

RSpec.describe Orders::DispatchRetryPolicy do
  subject(:policy) { described_class.new(base_seconds: 10, max_seconds: 300) }

  it "doubles the wait after each failed attempt" do
    expect((1..5).map { |attempt| policy.delay_for(attempt) }).to eq([ 10, 20, 40, 80, 160 ])
  end

  it "never waits more than the cap" do
    expect(policy.delay_for(6)).to eq(300)
  end

  describe "Retry-After" do
    it "waits longer when the store asks for it in seconds" do
      expect(policy.delay_for(1, retry_after: "120")).to eq(120)
    end

    it "keeps the backoff when the store asks for less" do
      expect(policy.delay_for(3, retry_after: "5")).to eq(40)
    end

    it "accepts an HTTP date" do
      freeze_time do
        expect(policy.delay_for(1, retry_after: 90.seconds.from_now.httpdate)).to eq(90)
      end
    end

    it "is capped as well" do
      expect(policy.delay_for(1, retry_after: "86400")).to eq(300)
    end

    it "is ignored when it is in the past or cannot be read" do
      expect(policy.delay_for(1, retry_after: 1.hour.ago.httpdate)).to eq(10)
      expect(policy.delay_for(1, retry_after: "soon")).to eq(10)
      expect(policy.delay_for(1, retry_after: "")).to eq(10)
    end
  end

  it "reads its values from the dispatch settings" do
    settings = ActiveSupport::OrderedOptions.new.merge!(retry_base_seconds: 2, retry_max_seconds: 30)

    expect(described_class.from_settings(settings).delay_for(5)).to eq(30)
  end
end
