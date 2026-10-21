# Loads the reference dataset from the technical test (db/data/*.json).
#
# The seeds are idempotent: running them again updates the existing rows
# instead of duplicating them. IDs are fixed because API payloads reference
# restaurants and products by the IDs given in the dataset.

def load_dataset(name)
  JSON.parse(Rails.root.join("db/data/#{name}.json").read, symbolize_names: true)
end

# Each store receives its orders at its own URL. By default they point to the
# simulated stores served by this same app; STORE_BASE_URL lets Docker or a
# real deployment point them somewhere else.
store_base_url = ENV.fetch("STORE_BASE_URL", "http://localhost:3000/simulated_stores")

restaurants = load_dataset("restaurants").map do |restaurant|
  restaurant.merge(dispatch_url: "#{store_base_url}/#{restaurant[:code]}/orders")
end

Restaurant.upsert_all(restaurants, unique_by: :id)
Product.upsert_all(load_dataset("products"), unique_by: :id)

# upsert_all writes explicit IDs, so the sequences must move past them for
# records created later to get a free ID.
[ Restaurant, Product ].each do |model|
  model.connection.reset_pk_sequence!(model.table_name)
end

puts "Seeded #{Restaurant.count} restaurants and #{Product.count} products"
