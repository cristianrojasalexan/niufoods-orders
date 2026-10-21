module Api
  module V1
    class OrdersController < BaseController
      # The contract sends a flat JSON object; wrapping it under "order" lets
      # strong params expect it. customer and items are not Order columns,
      # so they are listed explicitly.
      wrap_parameters :order, include: %i[restaurant_id order_type customer delivery_address items total_amount],
                              format: :json

      def create
        result = Orders::Create.call(order_params)

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

      def order_params
        params.expect(order: [
          :restaurant_id, :order_type, :delivery_address, :total_amount,
          customer: %i[name phone],
          items: [ %i[product_id quantity] ]
        ])
      end
    end
  end
end
