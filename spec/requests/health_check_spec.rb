require "rails_helper"

RSpec.describe "Health check", type: :request do
  it "responds with 200 when the app boots" do
    get rails_health_check_path

    expect(response).to have_http_status(:ok)
  end
end
