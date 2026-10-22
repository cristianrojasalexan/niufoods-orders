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

  DISPATCH_OUTCOME_LABELS = {
    "success" => "Entregada", "transient" => "Falla transitoria", "permanent" => "Rechazada", "stale" => "Descartado"
  }.freeze

  DISPATCH_OUTCOME_STYLES = {
    "success" => "bg-emerald-50 text-emerald-800 ring-emerald-600/20",
    "transient" => "bg-amber-50 text-amber-800 ring-amber-600/20",
    "permanent" => "bg-rose-50 text-rose-800 ring-rose-600/20",
    "stale" => "bg-slate-100 text-slate-700 ring-slate-500/20"
  }.freeze

  DISPATCH_OUTCOME_DOTS = {
    "success" => "bg-emerald-500", "transient" => "bg-amber-400", "permanent" => "bg-rose-500", "stale" => "bg-slate-400"
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
    badge(dispatch_status_label(order.dispatch_status), DISPATCH_STATUS_STYLES.fetch(order.dispatch_status))
  end

  def dispatch_outcome_badge(attempt)
    badge(DISPATCH_OUTCOME_LABELS.fetch(attempt.outcome), DISPATCH_OUTCOME_STYLES.fetch(attempt.outcome))
  end

  # In the time zone of the restaurants (config.time_zone).
  def order_time(time)
    tag.time(time.strftime("%d-%m-%Y %H:%M"), datetime: time.iso8601)
  end

  # With seconds, to follow the retries of a dispatch.
  def attempt_time(time)
    tag.time(time.strftime("%d-%m-%Y %H:%M:%S"), datetime: time.iso8601)
  end

  # "hace 3 min", for a quick read; the exact time goes next to it, so it
  # only keeps the largest unit.
  def relative_time(time, now: Time.current)
    seconds = (now - time).clamp(0..).round
    ago = case seconds
    when ...60 then "#{seconds} s"
    when ...3600 then "#{seconds / 60} min"
    when ...86_400 then "#{seconds / 3600} h"
    else "#{seconds / 86_400} d"
    end
    "hace #{ago}"
  end

  # A short duration: "4 s", "2 min 5 s", "3 h", "2 d".
  def duration_label(seconds)
    seconds = seconds.round
    return "#{seconds} s" if seconds < 60
    return [ "#{seconds / 60} min", ("#{seconds % 60} s" unless (seconds % 60).zero?) ].compact.join(" ") if seconds < 3600
    return "#{seconds / 3600} h" if seconds < 86_400

    "#{seconds / 86_400} d"
  end

  def dispatch_outcome_dot(attempt)
    tag.span(class: "absolute -left-[7px] top-1.5 h-3 w-3 rounded-full ring-4 ring-white #{DISPATCH_OUTCOME_DOTS.fetch(attempt.outcome)}")
  end

  # Attempts of each dispatch cycle, the latest cycle first.
  def attempts_by_cycle(order)
    order.dispatch_attempts.group_by(&:dispatch_cycle).sort.reverse
  end

  private

  def badge(label, style)
    tag.span(label, class: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset #{style}")
  end
end
