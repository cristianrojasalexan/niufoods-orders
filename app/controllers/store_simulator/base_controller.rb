module StoreSimulator
  # The simulated stores answer like a small external service, with their own
  # plain JSON, independent from the error format of the orders API.
  class BaseController < ActionController::API
    # The body is stored as it was dispatched, so it must not be wrapped.
    wrap_parameters false

    rescue_from ActiveRecord::RecordInvalid do |exception|
      render json: { error: exception.record.errors.full_messages.to_sentence }, status: :unprocessable_content
    end

    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render json: { error: "the request body is not valid JSON" }, status: :bad_request
    end

    private

    def store_code
      params[:code]
    end
  end
end
