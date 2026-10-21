#!/usr/bin/env ruby
# Simulates the digital channels: generates orders from the product dataset
# of the test and sends them to the API, mixing in invalid ones on purpose.
#
#   ruby script/simulate_orders.rb                     # 20 orders, ~20% invalid
#   ruby script/simulate_orders.rb --count 50 --invalid-ratio 0.3 --seed 42
#   ruby script/simulate_orders.rb --url http://localhost:3000
#
# Plain Ruby, no Rails: it reads db/data/*.json, the same dataset the seeds
# load, and talks to the API over HTTP like any external client would. It
# exits with status 1 if any order got an unexpected answer.
require "json"
require "net/http"
require "optparse"
require "securerandom"
require "uri"

module OrderSimulation
  DATA_DIR = File.expand_path("../db/data", __dir__)

  CUSTOMERS = [ "Ana Pérez", "Benjamín Soto", "Camila Rojas", "Diego Muñoz", "Fernanda Díaz",
                "Ignacio Vera", "Javiera Lagos", "Matías Fuentes", "Sofía Herrera", "Tomás Castro" ].freeze
  ADDRESSES = [ "Av. Providencia 1234, Santiago", "Av. Apoquindo 4500, Las Condes",
                "Irarrázaval 2800, Ñuñoa", "Los Leones 150, Providencia", "Av. Ossa 1950, Ñuñoa" ].freeze

  # Invalid orders the simulation sends on purpose, each derived from a valid
  # one. The API must reject all of them with 422.
  INVALID_KINDS = {
    unknown_product: "a product that is not in the catalog",
    zero_quantity: "a quantity of 0",
    decimal_quantity: "a quantity of 2.5, which must not be truncated",
    delivery_without_address: "a delivery order without address",
    tampered_total: "a total_amount lower than the real one",
    unknown_restaurant: "a restaurant that does not exist",
    no_items: "no products at all"
  }.freeze

  # One generated order and the answer the API is expected to give.
  Order = Struct.new(:kind, :payload, :expected_status, keyword_init: true) do
    def valid? = kind == :valid
  end

  class Generator
    def initialize(products:, restaurants:, random:)
      @products = products
      @restaurants = restaurants
      @random = random
    end

    def valid_order
      order_type = %w[pickup delivery].sample(random: random)
      items = products.sample(random.rand(1..5), random: random).map do |product|
        { "product_id" => product.fetch("id"), "quantity" => random.rand(1..4) }
      end
      payload = {
        "restaurant_id" => restaurants.sample(random: random).fetch("id"),
        "order_type" => order_type,
        "customer" => { "name" => CUSTOMERS.sample(random: random), "phone" => phone },
        "items" => items
      }
      payload["delivery_address"] = ADDRESSES.sample(random: random) if order_type == "delivery"
      # Half of the orders also send the total, as a channel that wants the
      # API to confirm its own calculation.
      payload["total_amount"] = total_of(items) if random.rand < 0.5
      Order.new(kind: :valid, payload: payload, expected_status: 201)
    end

    def invalid_order(kind = INVALID_KINDS.keys.sample(random: random))
      payload = valid_order.payload
      first_item = payload["items"].first
      case kind
      when :unknown_product then first_item["product_id"] = 9_999
      when :zero_quantity then first_item["quantity"] = 0
      when :decimal_quantity then first_item["quantity"] = 2.5
      when :delivery_without_address
        payload["order_type"] = "delivery"
        payload.delete("delivery_address")
      when :tampered_total then payload["total_amount"] = total_of(payload["items"]) - 1_000
      when :unknown_restaurant then payload["restaurant_id"] = 99
      when :no_items then payload["items"] = []
      else raise ArgumentError, "unknown invalid kind #{kind}"
      end
      Order.new(kind: kind, payload: payload, expected_status: 422)
    end

    private

    attr_reader :products, :restaurants, :random

    def phone
      "+569#{random.rand(10_000_000..99_999_999)}"
    end

    def total_of(items)
      prices = products.to_h { |product| [ product.fetch("id"), product.fetch("price") ] }
      items.sum { |item| prices.fetch(item["product_id"]) * item["quantity"] }
    end
  end

  # Sends an order to POST /api/v1/orders. Network problems are reported
  # as a result instead of stopping the simulation.
  class Client
    Response = Struct.new(:status, :body, :error, keyword_init: true)

    def initialize(base_url)
      @uri = URI.join(base_url, "/api/v1/orders")
    end

    def create_order(payload)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json",
                                         "Idempotency-Key" => SecureRandom.uuid)
      request.body = JSON.generate(payload)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: 3, read_timeout: 10) do |http|
        http.request(request)
      end
      Response.new(status: response.code.to_i, body: parse(response.body))
    rescue SystemCallError, IOError, Timeout::Error, SocketError => e
      Response.new(error: "#{e.class}: #{e.message}")
    end

    private

    attr_reader :uri

    def parse(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      {}
    end
  end

  # Runs the simulation and prints every answer and a summary.
  class Run
    Outcome = Struct.new(:order, :response, keyword_init: true) do
      def as_expected? = response.status == order.expected_status
      def network_error? = !response.error.nil?
    end

    def initialize(count:, invalid_ratio:, client:, generator:, random:, out: $stdout)
      @count = count
      @invalid_ratio = invalid_ratio
      @client = client
      @generator = generator
      @random = random
      @out = out
    end

    def call
      outcomes = Array.new(count) do |index|
        order = random.rand < invalid_ratio ? generator.invalid_order : generator.valid_order
        Outcome.new(order: order, response: client.create_order(order.payload)).tap do |outcome|
          out.puts line(index + 1, outcome)
        end
      end
      out.puts summary(outcomes)
      outcomes
    end

    private

    attr_reader :count, :invalid_ratio, :client, :generator, :random, :out

    def line(number, outcome)
      order = outcome.order
      mark = outcome.as_expected? ? "ok " : "!! "
      label = order.valid? ? "valid" : "invalid: #{INVALID_KINDS.fetch(order.kind)}"
      "#{mark}#{format('%3d', number)}. #{label.ljust(55)} -> #{answer(outcome)}"
    end

    def answer(outcome)
      response = outcome.response
      return "network error (#{response.error})" if outcome.network_error?

      body = response.body
      if response.status == 201
        "201 #{body['number']} #{body['order_type']} $#{body['total_amount']} (#{body.dig('restaurant', 'code')})"
      elsif body["errors"].is_a?(Array)
        codes = body["errors"].map { |error| [ error["field"], error["code"] ].compact.join(":") }
        "#{response.status} #{codes.join(', ')}"
      else
        response.status.to_s
      end
    end

    def summary(outcomes)
      created = outcomes.select { |outcome| outcome.response.status == 201 }
      invalid = outcomes.reject { |outcome| outcome.order.valid? }
      unexpected = outcomes.reject(&:as_expected?)

      lines = [ "", "Summary", "-------" ]
      lines << "Orders sent:             #{outcomes.size}"
      lines << "Created (201):           #{created.size}"
      lines << "Invalid on purpose:      #{invalid.size} (rejected with 422: #{invalid.count(&:as_expected?)})"
      lines << "Network errors:          #{outcomes.count(&:network_error?)}"
      lines << "Unexpected answers:      #{unexpected.size}"
      if created.any?
        lines << "Created by restaurant:   #{tally(created) { |body| body.dig('restaurant', 'code') }}"
        lines << "Created by order type:   #{tally(created) { |body| body['order_type'] }}"
        lines << "Total amount created:    $#{created.sum { |outcome| outcome.response.body['total_amount'].to_i }}"
      end
      lines.join("\n")
    end

    def tally(outcomes)
      outcomes.map { |outcome| yield(outcome.response.body) }.tally.sort.map { |key, value| "#{key}=#{value}" }.join(", ")
    end
  end

  def self.load_dataset(name)
    JSON.parse(File.read(File.join(DATA_DIR, "#{name}.json")))
  end

  def self.parse_options(argv)
    options = { url: ENV.fetch("SIMULATION_URL", "http://localhost:3000"), count: 20, invalid_ratio: 0.2, seed: nil }
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby script/simulate_orders.rb [options]"
      parser.on("--url URL", "API base URL (default: #{options[:url]})") { |value| options[:url] = value }
      parser.on("--count N", Integer, "Orders to send (default: 20)") { |value| options[:count] = value }
      parser.on("--invalid-ratio R", Float, "Share of invalid orders, 0 to 1 (default: 0.2)") do |value|
        raise OptionParser::InvalidArgument, "--invalid-ratio must be between 0 and 1" unless value.between?(0, 1)

        options[:invalid_ratio] = value
      end
      parser.on("--seed N", Integer, "Random seed, to repeat the same orders") { |value| options[:seed] = value }
    end.parse!(argv)
    options
  end

  def self.main(argv)
    options = parse_options(argv)
    seed = options[:seed] || Random.new_seed % 100_000
    random = Random.new(seed)
    puts "Sending #{options[:count]} orders to #{options[:url]} (seed #{seed}, " \
         "~#{(options[:invalid_ratio] * 100).round}% invalid)"
    puts

    generator = Generator.new(products: load_dataset("products"), restaurants: load_dataset("restaurants"),
                              random: random)
    outcomes = Run.new(count: options[:count], invalid_ratio: options[:invalid_ratio],
                       client: Client.new(options[:url]), generator: generator, random: random).call
    outcomes.all?(&:as_expected?) ? 0 : 1
  end
end

exit OrderSimulation.main(ARGV) if $PROGRAM_NAME == __FILE__
