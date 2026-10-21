module Api
  module V1
    # Base for the JSON API. ActionController::API skips the browser stack
    # (cookies, CSRF, views) that the dashboard controllers use.
    #
    # Every error is rendered with the same shape, so clients handle a single
    # format whatever went wrong:
    #
    #   { "errors": [ { "field": "items[0].quantity", "code": "invalid_quantity", "message": "..." } ] }
    #
    # field is null when the error is not about a specific attribute.
    class BaseController < ActionController::API
      rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_malformed_json
      rescue_from ActionController::BadRequest, with: :render_bad_request
      rescue_from ActionController::ParameterMissing, with: :render_parameter_missing
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

      private

      def render_errors(status, errors)
        render json: { errors: errors.map { |error| error.to_h.slice(:field, :code, :message) } }, status: status
      end

      def render_error(status, code:, message:, field: nil)
        render_errors(status, [ { field: field, code: code, message: message } ])
      end

      def render_malformed_json(_exception)
        render_error(:bad_request, code: "malformed_json", message: "the request body is not valid JSON")
      end

      def render_bad_request(exception)
        render_error(:bad_request, code: "invalid_payload", message: exception.message)
      end

      # The only required root is the payload itself (wrapped as "order" from
      # the flat JSON), so the error refers to the body, not to a field the
      # client never sent.
      def render_parameter_missing(_exception)
        render_error(:bad_request, code: "missing_payload", message: "the request body must be a JSON object with the order")
      end

      def render_not_found(exception)
        render_error(:not_found, code: "not_found", message: "#{exception.model || 'record'} not found")
      end
    end
  end
end
