# Dashboard to review the orders received and their dispatch to the stores.
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
end
