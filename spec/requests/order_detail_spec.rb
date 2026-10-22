require "rails_helper"

RSpec.describe "Order detail", type: :request do
  let(:restaurant) { create(:restaurant, name: "Niu Foods Ñuñoa", code: "NUNO") }

  def page
    Nokogiri::HTML(response.body)
  end

  def attempt(order, cycle:, number:, outcome:, http_status: nil, error_message: nil)
    order.dispatch_attempts.create!(dispatch_cycle: cycle, attempt_number: number, dispatch_token: SecureRandom.uuid,
                                    outcome: outcome, http_status: http_status, error_message: error_message,
                                    duration_ms: 15)
  end

  def failed_order(**attributes)
    create(:order, restaurant: restaurant, **attributes).tap do |order|
      order.update_columns(dispatch_status: "failed", dispatch_attempts_count: 1,
                           last_dispatch_error: "store answered 422")
    end
  end

  describe "GET /orders/:id" do
    it "shows the products, quantities, prices and total" do
      burger = create(:product, name: "Hamburguesa Clásica", price: 8990)
      fries = create(:product, name: "Papas Fritas", price: 2490)
      order = build(:order, restaurant: restaurant).tap do |o|
        o.order_items.clear
        o.order_items.build(product: burger, quantity: 2)
        o.order_items.build(product: fries, quantity: 1)
        o.save!
      end

      get order_path(order)

      expect(response).to have_http_status(:ok)
      rows = page.css("section[aria-labelledby='items-title'] tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
      expect(rows).to eq([ [ "Hamburguesa Clásica", "2", "$ 8.990", "$ 17.980" ], [ "Papas Fritas", "1", "$ 2.490", "$ 2.490" ] ])
      expect(page.css("tfoot").text.squish).to eq("Total $ 20.470")
    end

    it "shows the customer and the delivery address" do
      order = create(:order, :delivery, restaurant: restaurant, customer_name: "Camila Rojas",
                                        customer_phone: "+56987654321")

      get order_path(order)

      customer = page.css("section[aria-labelledby='customer-title']").text.squish
      expect(customer).to include("Camila Rojas", "+56987654321", "Av. Providencia 1234, Santiago")
    end

    it "says that a pickup order has no delivery address" do
      get order_path(create(:order, restaurant: restaurant, order_type: "pickup"))

      expect(response.body).to include("No aplica: retiro en tienda")
    end

    it "shows the dispatch attempts as a timeline per cycle, the latest cycle first" do
      order = failed_order
      first = attempt(order, cycle: 1, number: 1, outcome: "transient", http_status: 503, error_message: "store answered 503")
      second = attempt(order, cycle: 1, number: 2, outcome: "permanent", http_status: 422, error_message: "store answered 422")
      second.update_columns(created_at: first.created_at + 4.seconds)
      attempt(order, cycle: 2, number: 1, outcome: "success", http_status: 201)

      get order_path(order)

      cycles = page.css("[id^='cycle_']")
      expect(cycles.map { |cycle| cycle.css("h3").text.squish }).to eq([ "Ciclo 2 · 1 intento", "Ciclo 1 · 2 intentos" ])
      steps = cycles.last.css("li").map { |step| step.text.squish }
      expect(steps.size).to eq(3)
      expect(steps[0]).to include("Intento 1", "Falla transitoria", "HTTP 503", "15 ms", "store answered 503")
      expect(steps[1]).to eq("4 s después")
      expect(steps[2]).to include("Intento 2", "Rechazada", "HTTP 422", "store answered 422")
    end

    it "shows the next attempt of a pending order and refreshes itself while it is in progress" do
      order = create(:order, restaurant: restaurant)
      order.update_columns(dispatch_attempts_count: 1, next_dispatch_at: 8.seconds.from_now)
      attempt(order, cycle: 1, number: 1, outcome: "transient", http_status: 503)

      get order_path(order)

      expect(page.css("#cycle_1 li").last.text.squish).to start_with("Próximo intento a las")
      expect(page.css("[data-controller='auto-refresh']")).to be_present
    end

    it "stops refreshing itself once the dispatch ends" do
      get order_path(failed_order)

      expect(page.css("[data-controller='auto-refresh']")).to be_empty
    end

    it "says when there are no attempts yet" do
      get order_path(create(:order, restaurant: restaurant))

      expect(response.body).to include("Todavía no hay intentos de despacho")
    end

    it "shows why a failed order could not be delivered and offers to retry it" do
      get order_path(failed_order)

      expect(response.body).to include("store answered 422")
      expect(page.css("form[action$='/redispatch'] button").text).to eq("Reintentar despacho")
      expect(page.css("form[action$='/redispatch'] input[name='cycle']").sole["value"]).to eq("1")
      expect(page.css("form[action$='/redispatch']").sole["data-turbo-confirm"]).to include("Se abrirá un ciclo nuevo")
      expect(page.css("form[action$='/redispatch'] button").sole["data-turbo-submits-with"]).to eq("Reintentando…")
    end

    it "does not offer to retry an order that is not failed" do
      order = create(:order, restaurant: restaurant)
      order.update_columns(dispatch_status: "dispatched", dispatched_at: Time.current)

      get order_path(order)

      expect(page.css("form[action$='/redispatch']")).to be_empty
    end

    it "is linked from the dashboard" do
      order = create(:order, restaurant: restaurant)

      get orders_path

      expect(page.css("tbody a").map { |link| link["href"] }).to eq([ order_path(order) ])
    end

    it "answers 404 for an unknown order" do
      get order_path(id: 0)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /orders/:id/redispatch" do
    it "opens a new dispatch cycle for a failed order and enqueues it" do
      order = failed_order

      post redispatch_order_path(order), params: { cycle: 1 }

      expect(response).to redirect_to(order_path(order))
      expect(response).to have_http_status(:see_other)
      expect(order.reload).to have_attributes(dispatch_status: "pending", dispatch_cycle: 2, dispatch_attempts_count: 0)
      expect(DispatchOrderJob.jobs.size).to eq(1)

      follow_redirect!
      expect(page.css("[role='status']").text).to include("Despacho reintentado", "ciclo 2")
      expect(page.css("form[action$='/redispatch']")).to be_empty
    end

    it "changes nothing when the order is no longer failed" do
      order = failed_order
      post redispatch_order_path(order), params: { cycle: 1 }
      DispatchOrderJob.clear

      post redispatch_order_path(order), params: { cycle: 1 }

      expect(order.reload.dispatch_cycle).to eq(2)
      expect(DispatchOrderJob.jobs).to be_empty
      follow_redirect!
      expect(page.css("[role='alert']").text).to include("No se reintentó")
    end

    it "does not open another cycle when the page showed an older one" do
      order = failed_order
      order.update_columns(dispatch_cycle: 2)

      post redispatch_order_path(order), params: { cycle: 1 }

      expect(order.reload).to have_attributes(dispatch_status: "failed", dispatch_cycle: 2)
      expect(DispatchOrderJob.jobs).to be_empty
    end

    it "answers 400 without the cycle" do
      post redispatch_order_path(failed_order)

      expect(response).to have_http_status(:bad_request)
    end

    it "answers 404 for an unknown order" do
      post redispatch_order_path(id: 0), params: { cycle: 1 }

      expect(response).to have_http_status(:not_found)
    end
  end
end
