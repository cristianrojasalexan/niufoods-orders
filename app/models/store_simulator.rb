# Simulated restaurant stores that receive the orders dispatched by the API.
#
# They stand in for the external system of each restaurant: they keep their
# own state in simulated_store_* tables and never touch the orders domain.
# In production each restaurant's dispatch_url would point to its real store
# instead.
module StoreSimulator
  def self.table_name_prefix
    "simulated_store_"
  end
end
