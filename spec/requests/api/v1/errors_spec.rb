require "rails_helper"

# Every API error uses the same shape: { errors: [ { field, code, message } ] }.
RSpec.describe "API v1 error responses", type: :request do
  let(:json) { response.parsed_body }

  def post_raw(body)
    post api_v1_orders_path, params: body, headers: { "CONTENT_TYPE" => "application/json" }
  end

  def expect_single_error(status, code)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/json")
    expect(json["errors"]).to contain_exactly(include("field" => nil, "code" => code, "message" => be_present))
  end

  it "returns 400 malformed_json when the body is not valid JSON" do
    post_raw('{"restaurant_id": 2,')

    expect_single_error(:bad_request, "malformed_json")
  end

  it "returns 400 missing_payload when the body is empty" do
    post_raw("{}")

    expect_single_error(:bad_request, "missing_payload")
  end

  it "returns 400 invalid_payload when order is not an object" do
    post_raw({ order: "oops" }.to_json)

    expect_single_error(:bad_request, "invalid_payload")
  end

  it "returns 404 not_found for unknown orders" do
    get api_v1_order_path(0)

    expect_single_error(:not_found, "not_found")
  end

  it "returns 422 with one entry per invalid field" do
    create(:restaurant, id: 2)
    post_raw({ restaurant_id: 2, order_type: "pickup", items: [ { product_id: 1, quantity: 0 } ] }.to_json)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"]).to all(match("field" => be_a(String), "code" => be_a(String), "message" => be_a(String)))
  end
end
