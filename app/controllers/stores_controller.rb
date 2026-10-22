# Control panel of the simulated stores, for demos: shows how each store is
# answering and what it received, and changes its mode without curl. It only
# reads and writes the simulator's own tables, through StoreSimulator.
class StoresController < ApplicationController
  # The modes offered by the panel; STORE_MODES may set others, which are
  # shown as they are.
  MODES = {
    "ok" => "Acepta",
    "flaky:2" => "Inestable",
    "reject" => "Rechaza",
    "down" => "Caída"
  }.freeze

  RECENT_LIMIT = 5

  def index
    @restaurants = Restaurant.order(:id)
    codes = @restaurants.map(&:code)
    requests = StoreSimulator::Request.where(store_code: codes)

    @modes = codes.index_with { |code| StoreSimulator::Mode.current(code) }
    @received_counts = requests.received.group(:store_code).count
    @request_counts = requests.group(:store_code).sum(:attempts)
    @recent = codes.index_with do |code|
      requests.received.where(store_code: code).order(received_at: :desc).limit(RECENT_LIMIT)
    end
    @live = Order.where(dispatch_status: OrdersController::ACTIVE_DISPATCH_STATUSES).exists?
  end

  def update
    restaurant = Restaurant.find_by!(code: params[:code])
    mode = params.expect(:mode)

    if MODES.key?(mode)
      StoreSimulator::Mode.change!(restaurant.code, mode)
      flash[:notice] = "#{restaurant.name} ahora responde en modo «#{MODES.fetch(mode)}»."
    else
      flash[:alert] = "Modo desconocido: #{mode}."
    end
    redirect_to stores_path, status: :see_other
  end
end
