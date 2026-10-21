FactoryBot.define do
  factory :order do
    restaurant
    order_type { "pickup" }
    customer_name { "Ana Pérez" }
    customer_phone { "+56912345678" }

    transient do
      items_count { 1 }
    end

    after(:build) do |order, context|
      if order.order_items.empty?
        context.items_count.times { order.order_items.build(product: create(:product), quantity: 1) }
      end
    end

    trait :delivery do
      order_type { "delivery" }
      delivery_address { "Av. Providencia 1234, Santiago" }
    end
  end
end
