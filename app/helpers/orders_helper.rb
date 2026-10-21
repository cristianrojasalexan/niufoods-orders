module OrdersHelper
  ORDER_TYPE_LABELS = { "pickup" => "Retiro", "delivery" => "Delivery" }.freeze

  DISPATCH_STATUS_LABELS = {
    "pending" => "Pendiente", "dispatching" => "Enviando", "dispatched" => "Enviada", "failed" => "Error"
  }.freeze

  DISPATCH_STATUS_STYLES = {
    "pending" => "bg-amber-50 text-amber-800 ring-amber-600/20",
    "dispatching" => "bg-sky-50 text-sky-800 ring-sky-600/20",
    "dispatched" => "bg-emerald-50 text-emerald-800 ring-emerald-600/20",
    "failed" => "bg-rose-50 text-rose-800 ring-rose-600/20"
  }.freeze

  # Chilean pesos: no decimals and a dot as thousands separator ($ 22.470).
  def clp(amount)
    number_to_currency(amount, unit: "$", delimiter: ".", precision: 0, format: "%u %n")
  end

  def order_type_label(order)
    ORDER_TYPE_LABELS.fetch(order.order_type)
  end

  def dispatch_status_label(status)
    DISPATCH_STATUS_LABELS.fetch(status)
  end

  def dispatch_status_badge(order)
    tag.span(dispatch_status_label(order.dispatch_status),
             class: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset " \
                    "#{DISPATCH_STATUS_STYLES.fetch(order.dispatch_status)}")
  end

  # In the time zone of the restaurants (config.time_zone).
  def order_time(time)
    tag.time(time.strftime("%d-%m-%Y %H:%M"), datetime: time.iso8601)
  end
end
