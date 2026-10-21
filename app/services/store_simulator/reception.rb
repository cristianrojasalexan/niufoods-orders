module StoreSimulator
  # Handles one delivery attempt of an order to a simulated store.
  #
  # Deduplication is atomic, so concurrent deliveries of the same order are
  # received exactly once:
  # 1. an upsert counts the attempt and returns whether the order was already
  #    received, in a single statement;
  # 2. the store mode decides the answer;
  # 3. only an accepted delivery marks the order as received, with an update
  #    conditioned on received_at still being empty. If a concurrent delivery
  #    got there first, this one is answered as a duplicate.
  #
  # Failed attempts are never recorded as receptions.
  class Reception
    HTTP_STATUS = { received: :created, duplicate: :ok, rejected: :unprocessable_content,
                    unavailable: :service_unavailable }.freeze

    Result = Data.define(:status, :attempts) do
      def http_status = HTTP_STATUS.fetch(status)
    end

    def self.call(store_code:, idempotency_key:, payload:)
      new(store_code, idempotency_key, payload).call
    end

    def initialize(store_code, idempotency_key, payload)
      @store_code = store_code
      @idempotency_key = idempotency_key
      @payload = payload
    end

    def call
      request_id, attempts, already_received = count_attempt
      return Result.new(status: :duplicate, attempts: attempts) if already_received

      status = answer(Mode.current(store_code), attempts)
      return Result.new(status: status, attempts: attempts) unless status == :received

      received = Request.where(id: request_id, received_at: nil)
                        .update_all(received_at: Time.current, payload: payload, updated_at: Time.current)
      Result.new(status: received == 1 ? :received : :duplicate, attempts: attempts)
    end

    private

    attr_reader :store_code, :idempotency_key, :payload

    def count_attempt
      row = Request.upsert(
        { store_code: store_code, idempotency_key: idempotency_key, attempts: 1 },
        unique_by: %i[store_code idempotency_key],
        on_duplicate: Arel.sql("attempts = simulated_store_requests.attempts + 1, updated_at = CURRENT_TIMESTAMP"),
        returning: %w[id attempts received_at]
      ).first
      [ row["id"], row["attempts"], !row["received_at"].nil? ]
    end

    def answer(mode, attempts)
      case mode
      when "ok" then :received
      when "reject" then :rejected
      when "down" then :unavailable
      when /\Aflaky:(\d+)\z/ then attempts <= Regexp.last_match(1).to_i ? :unavailable : :received
      end
    end
  end
end
