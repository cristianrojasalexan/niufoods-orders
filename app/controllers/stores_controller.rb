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

  # The restaurants and their modes come from StoresHelper#simulated_store_modes,
  # which the notice in the layout uses too.
  def index
    requests = StoreSimulator::Request.where(store_code: Restaurant.select(:code))

    @received_counts = requests.received.group(:store_code).count
    @request_counts = requests.group(:store_code).sum(:attempts)
    @recent = recent_receptions(requests).group_by(&:store_code)
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

  private

  # The last RECENT_LIMIT receptions of every store in a single query,
  # numbering each store's receptions from the newest.
  def recent_receptions(requests)
    ranked = requests.received.select(
      :id, :store_code, :idempotency_key, :attempts, :received_at,
      "ROW_NUMBER() OVER (PARTITION BY store_code ORDER BY received_at DESC, id DESC) AS position"
    )
    StoreSimulator::Request.from(ranked, :simulated_store_requests)
                           .where("position <= ?", RECENT_LIMIT).order(received_at: :desc, id: :desc)
  end
end
