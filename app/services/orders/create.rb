module Orders
  # Creates an order from the payload of POST /api/v1/orders.
  #
  #   result = Orders::Create.call(payload)
  #   result.success? # => true
  #   result.order    # => persisted Order
  #   result.errors   # => [] or [FieldError(field:, code:, message:)]
  #
  # The payload keeps the shape of the API contract (customer nested, items
  # as product_id/quantity pairs). The service checks the raw JSON types
  # before any conversion, consolidates repeated products, prices the items
  # from the catalog and saves the order with its items in one transaction.
  # A total sent by the client is only compared with the calculated one.
  class Create
    FieldError = Data.define(:field, :code, :message)

    Result = Data.define(:order, :errors) do
      def success? = errors.empty?
    end

    # Model attributes reported with the names of the API contract.
    FIELD_NAMES = {
      "customer_name" => "customer.name",
      "customer_phone" => "customer.phone",
      "restaurant" => "restaurant_id",
      "order_items" => "items",
      "order_items.quantity" => "items",
      "order_items.unit_price" => "items",
      "order_items.product" => "items"
    }.freeze

    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload.to_h.deep_stringify_keys
    end

    def call
      errors = payload_errors
      return failure(errors) if errors.any?

      items = consolidated_items
      restaurant = Restaurant.find_by(id: payload["restaurant_id"])
      products = Product.where(id: items.keys).index_by(&:id)
      errors = reference_errors(restaurant, items, products)
      return failure(errors) if errors.any?

      order = build_order(restaurant, items, products)
      return failure(model_errors(order)) unless order.valid?
      return failure([ total_mismatch_error(order) ]) if total_mismatch?(order)

      order.save!
      Result.new(order: order, errors: [])
    end

    private

    attr_reader :payload

    def failure(errors)
      Result.new(order: nil, errors: errors)
    end

    def error(field, code, message)
      FieldError.new(field: field, code: code.to_s, message: message)
    end

    # --- Raw payload checks, before any value is converted ----------------

    def payload_errors
      [
        *restaurant_id_errors,
        *customer_errors,
        *string_errors("delivery_address", payload["delivery_address"]),
        *items_errors,
        *total_amount_errors
      ]
    end

    def restaurant_id_errors
      value = payload["restaurant_id"]
      return [ error("restaurant_id", :blank, "can't be blank") ] if value.nil?
      return [] if positive_integer?(value)

      [ error("restaurant_id", :invalid_type, "must be a positive integer") ]
    end

    def customer_errors
      customer = payload["customer"]
      return [] if customer.nil?
      return [ error("customer", :invalid_type, "must be an object") ] unless customer.is_a?(Hash)

      [
        *string_errors("customer.name", customer["name"]),
        *string_errors("customer.phone", customer["phone"])
      ]
    end

    def string_errors(field, value)
      return [] if value.nil? || value.is_a?(String)

      [ error(field, :invalid_type, "must be a string") ]
    end

    def items_errors
      items = payload["items"]
      return [ error("items", :blank, "must include at least one product") ] if items.nil? || items == []
      return [ error("items", :invalid_type, "must be an array") ] unless items.is_a?(Array)

      items.each_with_index.flat_map { |item, index| item_errors(item, "items[#{index}]") }
    end

    def item_errors(item, field)
      return [ error(field, :invalid_type, "must be an object") ] unless item.is_a?(Hash)

      errors = []
      unless positive_integer?(item["product_id"])
        errors << error("#{field}.product_id", :invalid_type, "must be a positive integer")
      end
      unless valid_quantity?(item["quantity"])
        errors << error("#{field}.quantity", :invalid_quantity,
                        "must be an integer between 1 and #{OrderItem::MAX_QUANTITY}")
      end
      errors
    end

    def total_amount_errors
      value = payload["total_amount"]
      return [] if value.nil? || (value.is_a?(Integer) && value >= 0)

      [ error("total_amount", :invalid_type, "must be a non-negative integer") ]
    end

    # JSON numbers arrive as Integer or Float and are checked as they came:
    # 2.5, 2.0 or "2" are rejected instead of being truncated or converted.
    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def valid_quantity?(value)
      value.is_a?(Integer) && value.between?(1, OrderItem::MAX_QUANTITY)
    end

    # --- References to the catalog ----------------------------------------

    # A product listed twice becomes one item with the quantities added,
    # keeping the order in which products first appeared.
    def consolidated_items
      payload["items"].each_with_object({}) do |item, quantities|
        quantities[item["product_id"]] = quantities.fetch(item["product_id"], 0) + item["quantity"]
      end
    end

    def reference_errors(restaurant, items, products)
      errors = []
      errors << error("restaurant_id", :not_found, "does not exist") unless restaurant

      payload["items"].each_with_index do |item, index|
        next if products.key?(item["product_id"])

        errors << error("items[#{index}].product_id", :not_found, "does not exist")
      end

      items.each do |product_id, quantity|
        next if quantity <= OrderItem::MAX_QUANTITY

        errors << error("items", :invalid_quantity,
                        "product #{product_id} exceeds #{OrderItem::MAX_QUANTITY} units in total")
      end
      errors
    end

    # --- Order ------------------------------------------------------------

    def build_order(restaurant, items, products)
      customer = payload["customer"] || {}
      order = Order.new(
        restaurant: restaurant,
        order_type: payload["order_type"],
        customer_name: customer["name"],
        customer_phone: customer["phone"],
        # A pickup order has no use for an address, so it is not stored.
        delivery_address: (payload["delivery_address"] if payload["order_type"] == "delivery")
      )
      items.each do |product_id, quantity|
        order.order_items.build(product: products.fetch(product_id), quantity: quantity)
      end
      order
    end

    def model_errors(order)
      order.errors.map do |model_error|
        attribute = model_error.attribute.to_s
        error(FIELD_NAMES.fetch(attribute, attribute), model_error.type, model_error.message)
      end
    end

    def total_mismatch?(order)
      !payload["total_amount"].nil? && payload["total_amount"] != order.total_amount
    end

    def total_mismatch_error(order)
      error("total_amount", :total_mismatch, "does not match the calculated total of #{order.total_amount}")
    end
  end
end
