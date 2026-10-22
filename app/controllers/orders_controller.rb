class OrdersController < ApplicationController
  include Pagy::Method

  # Dispatch statuses still moving; while any order is in one of them, the
  # pages refresh themselves.
  ACTIVE_DISPATCH_STATUSES = %w[pending dispatching].freeze

  before_action { Pagy::I18n.locale = "es" }

  def index
    @filters = filter_params
    @restaurants = Restaurant.order(:id)

    # The counts by status follow the other filters, so each card tells how
    # many orders that status filter would show.
    orders = filtered_orders.order(created_at: :desc, id: :desc)
    @status_counts = orders.unscope(:order).group(:dispatch_status).count
    @live = ACTIVE_DISPATCH_STATUSES.any? { |status| @status_counts[status].to_i.positive? }

    orders = orders.where(dispatch_status: @filters[:status]) if @filters[:status]
    @pagy, @orders = pagy(:offset, orders.includes(:restaurant))

    # What needs attention, whatever the filters.
    @summary = Orders::DailySummary.call
    @failed_count = Order.dispatch_failed.count
    @degraded_stores = @restaurants.reject { |restaurant| StoreSimulator::Mode.current(restaurant.code) == "ok" }
  end

  def show
    @order = Order.includes(:restaurant, :dispatch_attempts, order_items: :product).find(params[:id])
    @live = @order.dispatch_status.in?(ACTIVE_DISPATCH_STATUSES)
  end

  # Opens a new dispatch cycle, only if the order is still failed in the
  # cycle the form was rendered for (see Orders::Redispatch).
  def redispatch
    order = Order.find(params[:id])
    if (cycle = Orders::Redispatch.call(order, cycle: Integer(params.expect(:cycle), exception: false)))
      flash[:notice] = "Despacho reintentado: la orden se enviará de nuevo a la tienda (ciclo #{cycle})."
    else
      flash[:alert] = "No se reintentó: la orden cambió desde que abriste la página. Puede que ya se haya reintentado, " \
                      "que haya un despacho en curso o que ya fuera entregada."
    end
    redirect_to order_path(order), status: :see_other
  end

  private

  # Unknown values are ignored instead of rejected, as they only come from
  # links and the filter form.
  def filter_params
    {
      status: params[:status].presence_in(Order.dispatch_statuses.keys),
      restaurant: params[:restaurant].presence_in(Restaurant.pluck(:code)),
      order_type: params[:order_type].presence_in(Order.order_types.keys),
      q: params[:q].to_s.strip.first(50).presence
    }
  end

  # Every filter except the dispatch status, which the cards apply.
  def filtered_orders
    orders = Order.all
    orders = orders.joins(:restaurant).where(restaurants: { code: @filters[:restaurant] }) if @filters[:restaurant]
    orders = orders.where(order_type: @filters[:order_type]) if @filters[:order_type]
    orders = orders.where("orders.number ILIKE ?", "%#{Order.sanitize_sql_like(@filters[:q])}%") if @filters[:q]
    orders
  end
end
