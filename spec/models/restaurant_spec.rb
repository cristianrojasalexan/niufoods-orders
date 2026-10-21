require "rails_helper"

RSpec.describe Restaurant, type: :model do
  subject { build(:restaurant) }

  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to validate_presence_of(:code) }
  it { is_expected.to validate_uniqueness_of(:code) }
  it { is_expected.to validate_presence_of(:dispatch_url) }

  it "requires an uppercase code" do
    expect(build(:restaurant, code: "prov")).not_to be_valid
  end

  it "requires an http(s) dispatch_url" do
    expect(build(:restaurant, dispatch_url: "ftp://stores.test/orders")).not_to be_valid
    expect(build(:restaurant, dispatch_url: "https://stores.test/orders")).to be_valid
  end
end
