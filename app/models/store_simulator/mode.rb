module StoreSimulator
  # How a simulated store answers, so dispatch failures can be reproduced:
  #
  #   ok       accepts every order
  #   flaky:N  answers 503 to the first N attempts of each order, then accepts it
  #   reject   rejects every order with 422
  #   down     answers 503 to every request
  #
  # Stores without a saved mode use the STORE_MODES variable
  # (e.g. "PROV=ok,LCON=flaky:2") and then "ok".
  class Mode < ApplicationRecord
    FORMAT = /\A(ok|reject|down|flaky:\d{1,2})\z/
    CODE_FORMAT = /\A[A-Z]+\z/
    DEFAULT = "ok".freeze

    self.primary_key = :store_code

    validates :store_code, format: { with: CODE_FORMAT }
    validates :mode, format: { with: FORMAT, message: "must be ok, reject, down or flaky:N" }

    def self.current(store_code)
      find_by(store_code: store_code)&.mode || defaults.fetch(store_code, DEFAULT)
    end

    # A single upsert, so concurrent first changes of the same store do not
    # race to insert it. The mode is validated before writing.
    def self.change!(store_code, mode)
      record = new(store_code: store_code, mode: mode)
      record.validate!
      upsert({ store_code: store_code, mode: mode }, unique_by: :store_code)
      record
    end

    # Invalid entries are ignored so a typo in the variable cannot break the store.
    def self.defaults(variable = ENV.fetch("STORE_MODES", ""))
      variable.split(",").filter_map do |entry|
        code, mode = entry.split("=", 2).map(&:strip)
        [ code, mode ] if code&.match?(CODE_FORMAT) && mode&.match?(FORMAT)
      end.to_h
    end
  end
end
