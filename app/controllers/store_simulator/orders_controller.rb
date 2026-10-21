module StoreSimulator
  class OrdersController < BaseController
    # Receives an order dispatched by the API. Every delivery must carry an
    # Idempotency-Key so a retried order is received only once.
    def create
      key = request.headers["Idempotency-Key"]
      return render(json: { error: "Idempotency-Key header is required" }, status: :bad_request) if key.blank?

      payload = request.request_parameters
      if payload.empty? || payload.key?("_json")
        return render(json: { error: "the request body must be a JSON object" }, status: :bad_request)
      end

      result = Reception.call(store_code: store_code, idempotency_key: key, payload: payload)
      render json: { store: store_code, idempotency_key: key, status: result.status, attempts: result.attempts },
             status: result.http_status
    end

    # Orders this store was asked to receive, to check what arrived.
    def index
      requests = Request.where(store_code: store_code).order(created_at: :desc).limit(100)

      render json: {
        store: store_code,
        mode: Mode.current(store_code),
        orders: requests.map do |request|
          request.slice(:idempotency_key, :attempts, :received_at, :payload)
        end
      }
    end
  end
end
