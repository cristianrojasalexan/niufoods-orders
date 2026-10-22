class OrdersController < ApplicationController
  include Pagy::Method

  before_action { Pagy::I18n.locale = "es" }

  def index
    @status = params[:status].presence_in(Order.dispatch_statuses.keys)
    @status_counts = Order.group(:dispatch_status).count

    orders = Order.includes(:restaurant).order(created_at: :desc, id: :desc)
    orders = orders.where(dispatch_status: @status) if @status
    @pagy, @orders = pagy(:offset, orders)
  end

  def show
    @order = Order.includes(:restaurant, :dispatch_attempts, order_items: :product).find(params[:id])
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
end
