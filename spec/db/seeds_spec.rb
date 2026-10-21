require "rails_helper"

RSpec.describe "db/seeds.rb" do
  def run_seeds
    expect { load Rails.root.join("db/seeds.rb") }.to output(/Seeded/).to_stdout
  end

  it "loads the restaurants and products from the test dataset" do
    run_seeds

    expect(Restaurant.order(:id).pluck(:id, :code)).to eq([ [ 1, "PROV" ], [ 2, "LCON" ], [ 3, "NUNO" ] ])
    expect(Product.count).to eq(10)
    expect(Product.find(1)).to have_attributes(name: "Niu Roll Salmón", sku: "SKU-001", price: 8990)
    expect(Product.find(10)).to have_attributes(name: "Agua Mineral 500 ml", sku: "SKU-010", price: 1590)
  end

  it "points each restaurant to its simulated store" do
    run_seeds

    expect(Restaurant.find(2).dispatch_url).to eq("http://localhost:3000/simulated_stores/LCON/orders")
  end

  it "can run several times without duplicating records" do
    2.times { run_seeds }

    expect(Restaurant.count).to eq(3)
    expect(Product.count).to eq(10)
  end

  it "restores dataset values that were changed" do
    run_seeds
    Product.find(1).update!(price: 1)

    run_seeds

    expect(Product.find(1).price).to eq(8990)
  end

  it "leaves the ID sequences ready for new records" do
    run_seeds

    expect(create(:product).id).to eq(11)
  end
end
