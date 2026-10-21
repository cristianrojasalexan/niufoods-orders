require "rails_helper"

RSpec.describe HttpUrlValidator do
  let(:model) do
    Class.new do
      include ActiveModel::Validations

      def self.name = "Endpoint"

      attr_accessor :url

      validates :url, http_url: true
    end
  end

  def valid?(url)
    model.new.tap { |record| record.url = url }.valid?
  end

  it "accepts absolute http and https URLs" do
    expect(valid?("http://stores.test/PROV/orders")).to be(true)
    expect(valid?("https://stores.test:8443/orders")).to be(true)
    expect(valid?("http://localhost:3000/simulated_stores/LCON/orders")).to be(true)
  end

  it "rejects URLs without a host" do
    expect(valid?("http://")).to be(false)
    expect(valid?("https:///orders")).to be(false)
  end

  it "rejects other schemes even if an http URL appears inside" do
    expect(valid?("ftp://stores.test/http://orders")).to be(false)
  end

  it "rejects values that only contain a URL" do
    expect(valid?("garbage https://stores.test/orders garbage")).to be(false)
  end

  it "rejects relative paths and blank values" do
    expect(valid?("/simulated_stores/PROV/orders")).to be(false)
    expect(valid?("")).to be(false)
    expect(valid?(nil)).to be(false)
  end

  it "adds a descriptive error message" do
    record = model.new.tap { |r| r.url = "http://" }
    record.valid?

    expect(record.errors[:url]).to eq([ "must be an absolute http(s) URL with a host" ])
  end
end
