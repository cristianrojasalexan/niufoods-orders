require "rails_helper"
load Rails.root.join("script/demo_scenarios.rb")

RSpec.describe DemoScenarios do
  let(:settings) { Rails.configuration.x.dispatch }
  let(:client) { DemoScenarios::Client.new("http://demo.test") }
  let(:out) { StringIO.new }

  # The demo talks to the API and to the stores of this same app, and the
  # dispatcher delivers to the stores of the seeds. Every request goes to
  # the app, and each wait of the demo runs the jobs Sidekiq would run.
  before do
    expect { load Rails.root.join("db/seeds.rb") }.to output.to_stdout
    stub_request(:any, /demo\.test/).to_rack(Rails.application)
    stub_request(:any, %r{localhost:3000/simulated_stores}).to_rack(Rails.application)
    # Retries due at once, so draining the queue runs them without waiting.
    @retry_base_seconds = settings.retry_base_seconds
    settings.retry_base_seconds = 0
  end

  after { settings.retry_base_seconds = @retry_base_seconds }

  def run(scenarios: described_class.scenarios(max_attempts: settings.max_attempts_per_cycle), timeout: 30,
          wait: ->(_) { DispatchOrderJob.drain })
    DemoScenarios::Run.new(client: client, store: "PROV", restaurant_id: 1, product_id: 1, scenarios: scenarios,
                           timeout: timeout, poll_interval: 0, out: out, wait: wait).call
  end

  def store_mode
    StoreSimulator::Mode.current("PROV")
  end

  it "ends every scenario as expected" do
    results = run

    expect(results).to all(be_passed)
    expect(results.map { |result| [ result.status, result.attempts, result.received? ] })
      .to eq([ [ "dispatched", 1, true ], [ "dispatched", 3, true ], [ "failed", 1, false ], [ "failed", 5, false ] ])
    expect(out.string).to include("4 of 4 scenarios passed.")
  end

  it "prints the expected and obtained results of each scenario" do
    run

    expect(out.string).to include("flaky:2     dispatched, 3 attempts  dispatched, 3 attempts  yes (3 requests)  PASS")
    expect(out.string).to include("down        failed, 5 attempts      failed, 5 attempts      no (5 requests)   PASS")
  end

  it "reports a scenario that ends differently from what was expected" do
    wrong = DemoScenarios::Scenario.new(mode: "reject", description: "expects a delivery", status: "dispatched",
                                        attempts: 1, received: true)

    results = run(scenarios: [ wrong ])

    expect(results.sole).not_to be_passed
    expect(out.string).to include("FAIL", "0 of 1 scenarios passed.")
  end

  it "reports a scenario that does not reach a final status before the timeout" do
    ok = described_class.scenarios(max_attempts: 5).first

    results = run(scenarios: [ ok ], timeout: 0, wait: ->(_) { })

    expect(results.sole).to be_timed_out
    expect(out.string).to include("timeout", "check that Sidekiq is running")
  end

  describe "the store mode" do
    before { StoreSimulator::Mode.change!("PROV", "flaky:1") }

    it "is restored when the demo ends" do
      run

      expect(store_mode).to eq("flaky:1")
      expect(out.string).to include("Store PROV restored to mode flaky:1.")
    end

    it "is restored when the demo is interrupted" do
      expect { run(wait: ->(_) { raise Interrupt }) }.to raise_error(Interrupt)

      expect(store_mode).to eq("flaky:1")
    end

    it "is restored when the API stops answering" do
      allow(client).to receive(:order).and_raise(DemoScenarios::Error, "connection refused")

      expect { run }.to raise_error(DemoScenarios::Error)
      expect(store_mode).to eq("flaky:1")
    end
  end

  describe ".main" do
    it "exits with 1 and explains why when the API cannot be reached" do
      stub_request(:any, /unreachable\.test/).to_raise(Errno::ECONNREFUSED)

      expect(described_class.main(%w[--url http://unreachable.test], out: out)).to eq(1)
      expect(out.string).to include("Demo stopped:", "Connection refused")
    end

    it "only accepts the stores of the dataset" do
      expect { described_class.main(%w[--store XXXX], out: out) }.to raise_error(OptionParser::InvalidArgument)
    end
  end

  it "expects as many attempts as the cycle allows when the store is down" do
    expect(described_class.scenarios(max_attempts: 3).last).to have_attributes(mode: "down", attempts: 3)
    expect(described_class.parse_options(%w[--store LCON --timeout 200 --max-attempts 3]))
      .to include(store: "LCON", timeout: 200, max_attempts: 3)
  end
end
