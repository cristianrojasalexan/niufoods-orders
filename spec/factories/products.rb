FactoryBot.define do
  factory :product do
    sequence(:name) { |n| "Producto #{n}" }
    sequence(:sku) { |n| format("SKU-T%03d", n) }
    price { 4990 }
  end
end
