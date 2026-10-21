FactoryBot.define do
  factory :restaurant do
    sequence(:name) { |n| "Niu Foods Local #{n}" }
    sequence(:code) { |n| "LOC#{('A'..'Z').to_a[n % 26]}#{('A'..'Z').to_a[(n / 26) % 26]}" }
    dispatch_url { "http://stores.test/#{code}/orders" }
  end
end
