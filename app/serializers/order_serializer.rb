# JSON representation of an order in the API. It mirrors the request
# contract: the customer is nested again and items keep product_id and
# quantity, plus the prices that were applied.
class OrderSerializer
  def initialize(order)
    @order = order
  end

  def as_json(*)
    {
      id: order.id,
      number: order.number,
      restaurant: { id: order.restaurant.id, code: order.restaurant.code, name: order.restaurant.name },
      order_type: order.order_type,
      customer: { name: order.customer_name, phone: order.customer_phone },
      delivery_address: order.delivery_address,
      items: order.order_items.map { |item| item_json(item) },
      total_amount: order.total_amount,
      currency: "CLP",
      created_at: order.created_at.iso8601
    }
  end

  private

  attr_reader :order

  def item_json(item)
    {
      product_id: item.product_id,
      sku: item.product.sku,
      name: item.product.name,
      quantity: item.quantity,
      unit_price: item.unit_price,
      subtotal: item.subtotal
    }
  end
end
