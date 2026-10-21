module Orders
  # Creates an order from the payload of POST /api/v1/orders.
  #
  #   result = Orders::Create.call(payload, idempotency_key: "8f14e45f")
  #   result.status   # => :created, :replayed, :conflict or :invalid
  #   result.success? # => true when created or replayed
  #   result.order    # => the order, new or the one stored for the key
  #   result.errors   # => [] or [FieldError(field:, code:, message:)]
  #
  # The payload keeps the shape of the API contract (customer nested, items
  # as product_id/quantity pairs). The service checks the raw JSON types
  # before any conversion, consolidates repeated products, prices the items
  # from the catalog and saves the order with its items in one transaction.
  # A total sent by the client is only compared with the calculated one.
  #
  # With an Idempotency-Key, a retry of the same request returns the order
  # created the first time, exactly as it was stored: prices or a total that
  # changed since then are not checked again. The same key with a different
  # request is a conflict. A request rejected as invalid does not reserve
  # its key.
  class Create
    FieldError = Data.define(:field, :code, :message)

    Result = Data.define(:status, :order, :errors) do
      def success? = %i[created replayed].include?(status)
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

    def self.call(payload, idempotency_key: nil)
      new(payload, idempotency_key: idempotency_key).call
    end

    def initialize(payload, idempotency_key: nil)
      @payload = payload.to_h.deep_stringify_keys
      @idempotency_key = idempotency_key
    end

    def call
      errors = payload_errors
      return failure(errors) if errors.any?

      items = consolidated_items
      fingerprint = RequestFingerprint.call(payload, items)
      existing = previous_order
      return replay_or_conflict(existing, fingerprint) if existing

      create(items, fingerprint)
    end

    private

    attr_reader :payload, :idempotency_key

    def create(items, fingerprint)
      restaurant = Restaurant.find_by(id: payload["restaurant_id"])
      products = Product.where(id: items.keys).index_by(&:id)
      errors = reference_errors(restaurant, items, products)
      return failure(errors) if errors.any?

      order = build_order(restaurant, items, products)
      order.assign_attributes(idempotency_key: idempotency_key, request_fingerprint: (fingerprint if idempotency_key))
      return failure(model_errors(order)) unless order.valid?
      return failure([ total_mismatch_error(order) ]) if total_mismatch?(order)

      save(order, fingerprint)
    end

    # A savepoint keeps an enclosing transaction usable if the insert loses
    # the race for the key.
    def save(order, fingerprint)
      Order.transaction(requires_new: true) { order.save! }
      enqueue_dispatch(order)
      Result.new(status: :created, order: order, errors: [])
    rescue ActiveRecord::RecordNotUnique => e
      raise unless idempotency_key && (winner = previous_order)

      Rails.logger.info("Idempotency-Key #{idempotency_key} was taken by a concurrent request (#{e.class})")
      replay_or_conflict(winner, fingerprint)
    end

    # Enqueued only once the order is committed, so the worker never looks for
    # an order that does not exist yet, even if this runs inside a larger
    # transaction.
    #
    # The order is already saved when the job is pushed, so a Redis failure
    # must not turn a created order into an error: it stays pending and due,
    # and the dispatch recovery enqueues it once Redis is back.
    def enqueue_dispatch(order)
      ActiveRecord.after_all_transactions_commit do
        DispatchOrderJob.perform_async(order.id)
      rescue RedisClient::Error => e
        Rails.logger.warn("Order #{order.number} saved but its dispatch was not enqueued (#{e.class}: #{e.message}); " \
                          "it stays pending for the dispatch recovery")
      end
    end

    def previous_order
      Order.find_by(idempotency_key: idempotency_key) if idempotency_key
    end

    def replay_or_conflict(order, fingerprint)
      if order.request_fingerprint == fingerprint
        Result.new(status: :replayed, order: order, errors: [])
      else
        Result.new(status: :conflict, order: nil, errors: [
          error(nil, :idempotency_conflict, "the Idempotency-Key was already used with a different request")
        ])
      end
    end

    def failure(errors)
      Result.new(status: :invalid, order: nil, errors: errors)
    end

    def error(field, code, message)
      FieldError.new(field: field, code: code.to_s, message: message)
    end

    # --- Raw payload checks, before any value is converted ----------------

    def payload_errors
      [
        *restaurant_id_errors,
        *string_errors("order_type", payload["order_type"]),
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
