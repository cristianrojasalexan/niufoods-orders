module StoreSimulator
  # Reads or changes how a store answers, so dispatch failures can be
  # reproduced on demand (for example from the demo script).
  class ModesController < BaseController
    def show
      render json: { store: store_code, mode: Mode.current(store_code) }
    end

    def update
      mode = Mode.change!(store_code, params.expect(:mode))

      render json: { store: store_code, mode: mode.mode }
    end
  end
end
