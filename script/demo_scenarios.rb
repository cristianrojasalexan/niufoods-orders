#!/usr/bin/env ruby
# Shows the dispatch working end to end in four controlled scenarios: for
# each one it sets the mode of a simulated store, creates an order for it
# and waits until the dispatch reaches a final status.
#
#   ruby script/demo_scenarios.rb                    # store PROV, 120 s per scenario
#   ruby script/demo_scenarios.rb --store LCON --timeout 200
#
#   ok        the store accepts the order    -> dispatched after 1 attempt
#   flaky:2   503 twice, then accepts it     -> dispatched after 3 attempts
#   reject    the store answers 422          -> failed after 1 attempt
#   down      the store always answers 503   -> failed after 5 attempts
#
# The store mode is restored when the demo ends, also when a scenario fails
# or the demo is interrupted with Ctrl-C. It exits with status 1 if any
# scenario did not end as expected.
#
# Plain Ruby, no Rails: it talks to the API and the simulated stores over
# HTTP, so the API, Sidekiq and the stores must be running (docker compose
# up, or bin/dev).
require "json"
require "net/http"
require "openssl"
require "optparse"
require "securerandom"
require "uri"

module DemoScenarios
  DATA_DIR = File.expand_path("../db/data", __dir__)
  FINAL_STATUSES = %w[dispatched failed].freeze

  # What the scenario expects from the dispatch and from the store. received
  # tells whether the store must end up with the order.
  Scenario = Struct.new(:mode, :description, :status, :attempts, :received, keyword_init: true)

  def self.scenarios(max_attempts:)
    [
      Scenario.new(mode: "ok", description: "the store accepts the order",
                   status: "dispatched", attempts: 1, received: true),
      Scenario.new(mode: "flaky:2", description: "503 twice, then the store accepts it",
                   status: "dispatched", attempts: 3, received: true),
      Scenario.new(mode: "reject", description: "the store rejects the order with 422",
                   status: "failed", attempts: 1, received: false),
      Scenario.new(mode: "down", description: "the store always answers 503",
                   status: "failed", attempts: max_attempts, received: false)
    ]
  end

  # Raised when the API or a store cannot be reached or answers something
  # the demo cannot go on with.
  class Error < StandardError; end

  # HTTP calls to the orders API and to the simulated stores.
  class Client
    NETWORK_ERRORS = [ SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError,
                       Net::HTTPBadResponse, Net::ProtocolError ].freeze

    def initialize(base_url)
      @base_url = base_url
    end

    def create_order(payload)
      request(:post, "/api/v1/orders", payload, expect: 201, headers: { "Idempotency-Key" => SecureRandom.uuid })
    end

    def order(id)
      request(:get, "/api/v1/orders/#{id}", expect: 200)
    end

    def store_mode(store)
      request(:get, "/simulated_stores/#{store}/mode", expect: 200).fetch("mode")
    end

    def change_store_mode(store, mode)
      request(:put, "/simulated_stores/#{store}/mode", { "mode" => mode }, expect: 200)
    end

    # What the store recorded for an order: requests received and whether
    # it accepted it. The store identifies orders by their number.
    def store_request(store, order_number)
      request(:get, "/simulated_stores/#{store}/orders", expect: 200)
        .fetch("orders").find { |entry| entry["idempotency_key"] == order_number }
    end

    private

    attr_reader :base_url

    def request(method, path, body = nil, expect:, headers: {})
      uri = URI.join(base_url, path)
      request = Net::HTTP.const_get(method.capitalize).new(uri, { "Content-Type" => "application/json" }.merge(headers))
      request.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: 3, read_timeout: 10) do |http|
        http.request(request)
      end
      unless response.code.to_i == expect
        raise Error, "#{method.upcase} #{path} answered #{response.code}: #{response.body.to_s[0, 200]}"
      end

      JSON.parse(response.body)
    rescue *NETWORK_ERRORS, JSON::ParserError => e
      raise Error, "#{method.upcase} #{uri} failed (#{e.class}: #{e.message})"
    end
  end

  # How one scenario ended. status is nil when the order did not reach a
  # final status before the timeout.
  Result = Struct.new(:scenario, :order_number, :status, :attempts, :store_entry, :seconds, keyword_init: true) do
    def received? = !store_entry&.fetch("received_at").nil?
    def store_requests = store_entry ? store_entry.fetch("attempts") : 0
    def timed_out? = status.nil?

    def passed?
      status == scenario.status && attempts == scenario.attempts && received? == scenario.received &&
        store_requests == scenario.attempts
    end
  end

  class Run
    def initialize(client:, store:, restaurant_id:, product_id:, scenarios:, timeout:, poll_interval: 1, out: $stdout,
                   wait: ->(seconds) { sleep(seconds) })
      @client = client
      @store = store
      @restaurant_id = restaurant_id
      @product_id = product_id
      @scenarios = scenarios
      @timeout = timeout
      @poll_interval = poll_interval
      @out = out
      @wait = wait
    end

    # Runs every scenario in order and returns their results. The store goes
    # back to the mode it had before, whatever happens.
    def call
      original_mode = client.store_mode(store)
      out.puts "Store #{store} is in mode #{original_mode}; it will be restored at the end."
      out.puts
      results = scenarios.each_with_index.map { |scenario, index| run(scenario, index + 1) }
      out.puts
      out.puts table(results)
      results
    ensure
      restore(original_mode) if original_mode
    end

    private

    attr_reader :client, :store, :restaurant_id, :product_id, :scenarios, :timeout, :poll_interval, :out, :wait

    def run(scenario, number)
      client.change_store_mode(store, scenario.mode)
      out.print "#{number}. #{scenario.mode.ljust(8)} #{scenario.description.ljust(38)} "
      started_at = monotonic_now
      order = client.create_order(payload)
      out.print "#{order.fetch('number')} "
      final = wait_for_final_status(order.fetch("id"), started_at)
      result = Result.new(scenario: scenario, order_number: order.fetch("number"),
                          status: final&.dig("dispatch", "status"), attempts: final&.dig("dispatch", "attempts"),
                          store_entry: client.store_request(store, order.fetch("number")),
                          seconds: (monotonic_now - started_at).round(1))
      out.puts summary(result)
      result
    end

    def payload
      { "restaurant_id" => restaurant_id, "order_type" => "pickup",
        "customer" => { "name" => "Demo Niufoods", "phone" => "+56900000000" },
        "items" => [ { "product_id" => product_id, "quantity" => 1 } ] }
    end

    # Polls the order until its dispatch is dispatched or failed. Pending
    # between retries is not final. Returns nil after the timeout.
    def wait_for_final_status(id, started_at)
      loop do
        order = client.order(id)
        return order if FINAL_STATUSES.include?(order.dig("dispatch", "status"))
        return if monotonic_now - started_at >= timeout

        out.print "."
        wait.call(poll_interval)
      end
    end

    def summary(result)
      got = result.timed_out? ? "no final status after #{timeout}s" : "#{result.status}, #{attempts(result.attempts)}"
      " -> #{got} (#{result.seconds}s) #{result.passed? ? 'ok' : '!!'}"
    end

    def table(results)
      rows = results.map do |result|
        scenario = result.scenario
        [ scenario.mode, "#{scenario.status}, #{attempts(scenario.attempts)}",
          result.timed_out? ? "timeout" : "#{result.status}, #{attempts(result.attempts)}",
          "#{result.received? ? 'yes' : 'no'} (#{result.store_requests} #{result.store_requests == 1 ? 'request' : 'requests'})",
          result.passed? ? "PASS" : "FAIL" ]
      end
      header = [ "Store mode", "Expected", "Got", "Store received", "Result" ]
      widths = header.each_index.map { |index| ([ header ] + rows).map { |row| row[index].length }.max }
      lines = ([ header ] + rows).map { |row| row.each_with_index.map { |cell, index| cell.ljust(widths[index]) }.join("  ").rstrip }
      lines.insert(1, widths.map { |width| "-" * width }.join("  "))
      passed = results.count(&:passed?)
      lines << "" << "#{passed} of #{results.size} scenarios passed."
      lines << timeout_hint if results.any?(&:timed_out?)
      lines.join("\n")
    end

    def timeout_hint
      "A scenario timed out: check that Sidekiq is running. With the default DISPATCH_RETRY_BASE_SECONDS " \
        "of 10, run the demo with --timeout 200."
    end

    def attempts(count)
      "#{count} #{count == 1 ? 'attempt' : 'attempts'}"
    end

    def restore(mode)
      out.puts if $! # interrupted in the middle of a line
      client.change_store_mode(store, mode)
      out.puts "Store #{store} restored to mode #{mode}."
    rescue Error => e
      out.puts "Could not restore store #{store} to mode #{mode} (#{e.message}). Restore it with: " \
               "curl -X PUT .../simulated_stores/#{store}/mode -H 'Content-Type: application/json' -d '{\"mode\":\"#{mode}\"}'"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  def self.load_dataset(name)
    JSON.parse(File.read(File.join(DATA_DIR, "#{name}.json")))
  end

  def self.parse_options(argv)
    options = { url: ENV.fetch("SIMULATION_URL", "http://localhost:3000"), store: "PROV", timeout: 120,
                max_attempts: Integer(ENV.fetch("MAX_ATTEMPTS_PER_CYCLE", 5)) }
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby script/demo_scenarios.rb [options]"
      parser.on("--url URL", "API base URL (default: #{options[:url]})") { |value| options[:url] = value }
      parser.on("--store CODE", "Store used by the scenarios (default: PROV)") { |value| options[:store] = value }
      parser.on("--timeout SECONDS", Integer, "Wait per scenario (default: 120)") { |value| options[:timeout] = value }
      parser.on("--max-attempts N", Integer, "MAX_ATTEMPTS_PER_CYCLE of the API (default: 5)") do |value|
        options[:max_attempts] = value
      end
    end.parse!(argv)
    options
  end

  def self.main(argv, out: $stdout)
    options = parse_options(argv)
    restaurant = load_dataset("restaurants").find { |entry| entry["code"] == options[:store] }
    raise OptionParser::InvalidArgument, "--store must be one of the dataset stores" unless restaurant

    out.puts "Running #{scenarios(max_attempts: options[:max_attempts]).size} dispatch scenarios against " \
             "#{options[:url]} (timeout #{options[:timeout]}s each)"
    results = Run.new(client: Client.new(options[:url]), store: options[:store], restaurant_id: restaurant.fetch("id"),
                      product_id: load_dataset("products").first.fetch("id"),
                      scenarios: scenarios(max_attempts: options[:max_attempts]), timeout: options[:timeout],
                      out: out).call
    results.all?(&:passed?) ? 0 : 1
  rescue Error => e
    out.puts
    out.puts "Demo stopped: #{e.message}"
    1
  rescue Interrupt
    out.puts
    out.puts "Demo interrupted."
    130
  end
end

exit DemoScenarios.main(ARGV) if $PROGRAM_NAME == __FILE__
