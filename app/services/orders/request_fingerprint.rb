module Orders
  # Digest of the canonical form of an order request, used to tell a retry
  # of the same request from a different one that reuses its Idempotency-Key.
  #
  # Two payloads that describe the same order get the same fingerprint even
  # if they differ in form:
  # - items in another order, or a product split in several lines;
  # - surrounding spaces, or a phone written with spaces or dashes;
  # - an address sent with a pickup order, which is not stored;
  # - total_amount, which is derived from the items: it is checked against
  #   the prices when the order is created and ignored on retries.
  #
  # It expects a payload that already passed the type checks of
  # Orders::Create, and string keys.
  class RequestFingerprint
    def self.call(payload, items)
      new(payload, items).call
    end

    def initialize(payload, items)
      @payload = payload
      @items = items
    end

    def call
      Digest::SHA256.hexdigest(canonical.to_json)
    end

    def canonical
      customer = payload["customer"] || {}
      pickup = payload["order_type"] != "delivery"
      {
        restaurant_id: payload["restaurant_id"],
        order_type: payload["order_type"],
        customer: { name: normalize(:customer_name, customer["name"]), phone: normalize(:customer_phone, customer["phone"]) },
        delivery_address: (normalize(:delivery_address, payload["delivery_address"]) unless pickup),
        items: items.sort.map { |product_id, quantity| [ product_id, quantity ] }
      }
    end

    private

    attr_reader :payload, :items

    # Same normalization the order applies when it is saved.
    def normalize(attribute, value)
      Order.normalize_value_for(attribute, value) unless value.nil?
    end
  end
end
