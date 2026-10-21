require "rails_helper"

RSpec.describe Product, type: :model do
  subject { build(:product) }

  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to validate_presence_of(:sku) }
  it { is_expected.to validate_uniqueness_of(:sku) }
  it { is_expected.to validate_numericality_of(:price).only_integer.is_greater_than(0) }

  it "enforces a positive price in the database" do
    product = create(:product)

    expect { product.update_column(:price, 0) }.to raise_error(ActiveRecord::StatementInvalid, /products_price_positive/)
  end
end
