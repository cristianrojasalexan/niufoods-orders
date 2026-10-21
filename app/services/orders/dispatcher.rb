module Orders
  # Delivers an order to the store of its restaurant. PostgreSQL decides who
  # may deliver it; Sidekiq only runs the attempt (see docs/dispatch.md).
  #
  # 1. Claim: one conditional UPDATE moves the order to dispatching with a
  #    new token and a lease, if the order is due and has attempts left. If
  #    no row changes, someone else holds it or there is nothing to do.
  # 2. Deliver: POST the order to restaurant.dispatch_url with the order
  #    number as Idempotency-Key, so the store receives it only once.
  # 3. Finish: write the result only while the token is still ours. A worker
  #    that lost its lease cannot overwrite the result of the one that took
  #    over; its attempt is recorded as stale.
  #
  # Every attempt is recorded in dispatch_attempts.
  class Dispatcher
    Delivery = Data.define(:outcome, :http_status, :error_message, :duration_ms)

    # Worth retrying: the store may accept the order later.
    TRANSIENT_STATUSES = [ 408, 425, 429 ].freeze

    def self.call(order_id)
      new(order_id).call
    end

    def initialize(order_id, settings: Rails.configuration.x.dispatch)
      @order_id = order_id
      @settings = settings
    end

    # Returns the outcome of the attempt (:success, :transient, :permanent or
    # :stale), or :skipped when the order could not be claimed.
    def call
      token = SecureRandom.uuid
      return :skipped unless claim(token)

      order = Order.includes(:restaurant, order_items: :product).find(order_id)
      finish(order, token, deliver(order))
    end

    private

    attr_reader :order_id, :settings

    def claim(token)
      Order.where(id: order_id)
           .where("dispatch_attempts_count < ?", settings.max_attempts_per_cycle)
           .where(<<~SQL.squish)
             (dispatch_status = 'pending' AND next_dispatch_at <= now())
             OR (dispatch_status = 'dispatching' AND dispatch_lease_expires_at < now())
           SQL
           .update_all([ <<~SQL.squish, token, settings.lease_seconds ]) == 1
             dispatch_status = 'dispatching',
             dispatch_token = ?,
             dispatch_attempts_count = dispatch_attempts_count + 1,
             dispatch_lease_expires_at = now() + make_interval(secs => ?),
             updated_at = now()
           SQL
    end

    def deliver(order)
      started_at = monotonic_now
      response = http.post(order.restaurant.dispatch_url) do |request|
        request.headers["Content-Type"] = "application/json"
        request.headers["Idempotency-Key"] = order.number
        request.body = OrderSerializer.new(order).as_json.to_json
      end
      outcome = classify(response.status)
      Delivery.new(outcome: outcome, http_status: response.status, duration_ms: elapsed_ms(started_at),
                   error_message: ("store answered #{response.status}" unless outcome == :success))
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError => e
      Delivery.new(outcome: :transient, http_status: nil, duration_ms: elapsed_ms(started_at),
                   error_message: "#{e.class.name.demodulize}: #{e.message}".truncate(255))
    end

    def classify(status)
      return :success if (200..299).cover?(status)
      return :transient if status >= 500 || TRANSIENT_STATUSES.include?(status)

      :permanent
    end

    def finish(order, token, delivery)
      Order.transaction do
        applied = Order.where(id: order.id, dispatch_token: token).update_all(result_columns(delivery)) == 1
        outcome = applied ? delivery.outcome : :stale
        record_attempt(order, token, delivery, outcome)
        outcome
      end
    end

    def result_columns(delivery)
      columns = { dispatch_token: nil, dispatch_lease_expires_at: nil, updated_at: Time.current }
      if delivery.outcome == :success
        columns.merge(dispatch_status: "dispatched", dispatched_at: Time.current, last_dispatch_error: nil)
      else
        columns.merge(dispatch_status: "failed", last_dispatch_error: delivery.error_message)
      end
    end

    def record_attempt(order, token, delivery, outcome)
      order.dispatch_attempts.create!(
        dispatch_cycle: order.dispatch_cycle,
        attempt_number: order.dispatch_attempts_count,
        dispatch_token: token,
        outcome: outcome,
        http_status: delivery.http_status,
        error_message: stale_message(delivery, outcome) || delivery.error_message,
        duration_ms: delivery.duration_ms
      )
    end

    def stale_message(delivery, outcome)
      "lease lost before finishing; the delivery result (#{delivery.outcome}) was discarded" if outcome == :stale
    end

    def http
      @http ||= Faraday.new(request: { open_timeout: settings.open_timeout_seconds,
                                       timeout: settings.read_timeout_seconds })
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_now - started_at) * 1000).round
    end
  end
end
