module Api
  module V1
    class OrdersController < BaseController
      ORDER_ATTRIBUTES = %i[restaurant_id order_type delivery_address total_amount].freeze
      CUSTOMER_ATTRIBUTES = %i[name phone].freeze
      ITEM_ATTRIBUTES = %i[product_id quantity].freeze

      # The contract sends a flat JSON object; wrapping it under "order" lets
      # strong params require it. customer and items are not Order columns,
      # so they are listed explicitly.
      wrap_parameters :order, include: [ *ORDER_ATTRIBUTES, :customer, :items ], format: :json

      def create
        result = Orders::Create.call(order_payload)

        if result.success?
          render json: OrderSerializer.new(result.order).as_json,
                 status: :created, location: api_v1_order_url(result.order)
        else
          render json: { errors: result.errors.map(&:to_h) }, status: :unprocessable_content
        end
      end

      def show
        order = Order.includes(:restaurant, order_items: :product).find(params[:id])

        render json: OrderSerializer.new(order).as_json
      end

      private

      # Strong params drop values whose shape does not match silently: an
      # item sent as 17 or a total sent as [1] would vanish and the order
      # would be accepted without them. The submitted payload is projected
      # onto the same allowed keys without dropping anything by type; when it
      # differs from the permitted one, Orders::Create receives it so it can
      # reject the wrong shapes with their real position.
      def order_payload
        permitted = order_params.to_h
        submitted = submitted_payload
        permitted == submitted ? permitted : submitted
      end

      def order_params
        order_root.permit(*ORDER_ATTRIBUTES, customer: CUSTOMER_ATTRIBUTES, items: ITEM_ATTRIBUTES)
      end

      # require only checks presence: {"order": "oops"} or {"order": [1]}
      # would reach permit and fail with a 500. The root must be an object.
      def order_root
        @order_root ||= params.require(:order).tap do |root|
          raise ActionController::BadRequest, "order must be a JSON object" unless root.is_a?(ActionController::Parameters)
        end
      end

      # Keeps only the allowed keys at every level, like order_params, but
      # leaves values of an unexpected type in place.
      def submitted_payload
        raw = order_root.to_unsafe_h
        payload = raw.slice(*ORDER_ATTRIBUTES)
        payload["customer"] = only(raw["customer"], CUSTOMER_ATTRIBUTES) if raw.key?("customer")
        if raw.key?("items")
          items = raw["items"]
          payload["items"] = items.is_a?(Array) ? items.map { |item| only(item, ITEM_ATTRIBUTES) } : items
        end
        payload
      end

      def only(value, keys)
        value.is_a?(Hash) ? value.slice(*keys.map(&:to_s)) : value
      end
    end
  end
end
