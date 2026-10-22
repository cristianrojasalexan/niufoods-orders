module StoresHelper
  STORE_MODE_DESCRIPTIONS = {
    "ok" => "Acepta cada orden.",
    "flaky:2" => "Responde 503 a los dos primeros intentos de cada orden y después la acepta.",
    "reject" => "Rechaza cada orden con 422: queda con error, sin reintentos.",
    "down" => "Responde 503 siempre: cada orden agota sus intentos y queda con error."
  }.freeze

  STORE_MODE_STYLES = {
    "ok" => "bg-emerald-50 text-emerald-800 ring-emerald-600/20",
    "reject" => "bg-rose-50 text-rose-800 ring-rose-600/20",
    "down" => "bg-rose-50 text-rose-800 ring-rose-600/20"
  }.freeze

  # Every restaurant with the mode of its simulated store, read once per
  # request: the notice on every page and the stores panel share it.
  def simulated_store_modes
    @simulated_store_modes ||= begin
      restaurants = Restaurant.order(:id).to_a
      modes = StoreSimulator::Mode.current_for(restaurants.map(&:code))
      restaurants.to_h { |restaurant| [ restaurant, modes.fetch(restaurant.code) ] }
    end
  end

  # Simulated stores that do not accept every order, for the notice shown on
  # every page.
  def degraded_simulated_stores
    @degraded_simulated_stores ||=
      simulated_store_modes.reject { |_restaurant, mode| StoreSimulator::Mode.accepts_every_order?(mode) }
  end

  # Modes set through STORE_MODES that the panel does not offer, such as
  # flaky:3, are shown as they are.
  def store_mode_label(mode)
    StoresController::MODES.fetch(mode, mode)
  end

  def store_mode_badge(mode)
    tag.span(store_mode_label(mode),
             class: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset " \
                    "#{STORE_MODE_STYLES.fetch(mode, 'bg-amber-50 text-amber-800 ring-amber-600/20')}")
  end
end
