require "rails_helper"

RSpec.describe "Orders dashboard", type: :request do
  let(:restaurant) { create(:restaurant, name: "Niu Foods Las Condes", code: "LCON") }

  # The columns each status requires by the database constraints.
  def state_columns(status)
    case status
    when "dispatching" then { dispatch_token: SecureRandom.uuid, dispatch_lease_expires_at: 1.minute.from_now }
    when "dispatched" then { dispatched_at: Time.current }
    else {}
    end
  end

  def order_with(status, created_at: Time.current, **attributes)
    columns = state_columns(status)
    create(:order, restaurant: restaurant, **attributes).tap do |order|
      order.update_columns(dispatch_status: status, created_at: created_at, **columns)
    end
  end

  def rows
    Nokogiri::HTML(response.body).css("tbody tr")
  end

  it "is the home page" do
    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Órdenes")
  end

  it "shows the information required for each order" do
    product = create(:product, price: 11_235)
    order = build(:order, :delivery, restaurant: restaurant).tap do |o|
      o.order_items.clear
      o.order_items.build(product: product, quantity: 2)
      o.save!
    end
    order.update_columns(created_at: Time.utc(2026, 10, 21, 15, 30), dispatch_status: "dispatched",
                         dispatched_at: Time.utc(2026, 10, 21, 15, 30))

    travel_to(Time.utc(2026, 10, 21, 15, 35)) { get orders_path }

    cells = rows.sole.css("td").map { |cell| cell.text.squish }
    expect(cells).to eq([ order.number, "Niu Foods Las Condes", "$ 22.470", "Delivery", "21-10-2026 12:30 hace 5 min", "Enviada" ])
  end

  it "shows times in the time zone of Santiago" do
    order_with("pending", created_at: Time.utc(2026, 1, 15, 3, 5))

    get orders_path

    expect(rows.sole.css("time").text).to eq("15-01-2026 00:05")
  end

  it "labels pickup orders as Retiro" do
    order_with("pending", order_type: "pickup")

    get orders_path

    expect(rows.sole.text).to include("Retiro")
  end

  it "shows every dispatch status and the attempts of retried orders" do
    %w[pending dispatching dispatched failed].each { |status| order_with(status) }
    order_with("pending").update_columns(dispatch_attempts_count: 3)

    get orders_path

    expect(response.body).to include("Pendiente", "Enviando", "Enviada", "Error", "3 intentos")
  end

  it "lists the newest orders first" do
    older = order_with("pending", created_at: 2.hours.ago)
    newer = order_with("pending", created_at: 1.minute.ago)

    get orders_path

    expect(rows.map { |row| row["id"] }).to eq([ "order_#{newer.id}", "order_#{older.id}" ])
  end

  describe "filter by dispatch status" do
    before do
      order_with("failed")
      2.times { order_with("dispatched") }
    end

    it "shows only the orders with that status" do
      get orders_path(status: "failed")

      expect(rows.size).to eq(1)
      expect(rows.sole.text).to include("Error")
    end

    it "shows the count of each status" do
      get orders_path

      counts = Nokogiri::HTML(response.body).css("nav[aria-label='Filtrar por estado de despacho'] a")
                       .to_h { |link| link.css("span").map(&:text).then { |label, count| [ label, count.to_i ] } }
      expect(counts).to eq("Todas" => 3, "Pendiente" => 0, "Enviando" => 0, "Enviada" => 2, "Error" => 1)
    end

    it "ignores unknown statuses" do
      get orders_path(status: "drop table")

      expect(rows.size).to eq(3)
    end
  end

  describe "filters and search" do
    let(:providencia) { create(:restaurant, name: "Niu Foods Providencia", code: "PROV") }

    def numbers
      rows.map { |row| row.css("td").first.text.squish }
    end

    let!(:lcon_delivery) { order_with("dispatched", order_type: "delivery", delivery_address: "Av. Ossa 1950") }
    let!(:lcon_pickup) { order_with("failed", order_type: "pickup") }
    let!(:prov_pickup) do
      create(:order, restaurant: providencia, order_type: "pickup").tap do |order|
        order.update_columns(dispatch_status: "dispatched", dispatched_at: Time.current)
      end
    end

    it "filters by store" do
      get orders_path(restaurant: "PROV")

      expect(numbers).to eq([ prov_pickup.number ])
    end

    it "filters by order type" do
      get orders_path(order_type: "pickup")

      expect(numbers).to contain_exactly(lcon_pickup.number, prov_pickup.number)
    end

    it "searches by part of the order number, ignoring case" do
      get orders_path(q: prov_pickup.number.downcase.delete_prefix("prov"))

      expect(numbers).to eq([ prov_pickup.number ])
    end

    it "combines the filters and counts each status within them" do
      get orders_path(restaurant: "LCON", order_type: "pickup")

      expect(numbers).to eq([ lcon_pickup.number ])
      cards = Nokogiri::HTML(response.body).css("nav[aria-label='Filtrar por estado de despacho'] a")
      expect(cards.to_h { |link| link.css("span").map(&:text).then { |label, count| [ label, count.to_i ] } })
        .to include("Todas" => 1, "Error" => 1, "Enviada" => 0)
      expect(cards.map { |link| link["href"] }).to all(include("restaurant=LCON", "order_type=pickup"))
    end

    it "keeps the dispatch status filter when other filters are applied" do
      get orders_path(status: "dispatched", restaurant: "LCON")

      expect(numbers).to eq([ lcon_delivery.number ])
      expect(Nokogiri::HTML(response.body).css("form[role='search'] input[name='status']").sole["value"]).to eq("dispatched")
    end

    it "ignores unknown values" do
      get orders_path(restaurant: "XXXX", order_type: "drone")

      expect(rows.size).to eq(3)
    end

    it "says when no order matches" do
      get orders_path(q: "NOPE")

      expect(response.body).to include("Ninguna orden coincide con los filtros.")
    end
  end

  describe "live refresh" do
    def live_indicator
      Nokogiri::HTML(response.body).css("[data-controller='auto-refresh']")
    end

    it "refreshes itself while some dispatch is pending or being sent" do
      order_with("dispatched")
      order_with("dispatching")

      get orders_path

      expect(live_indicator.text).to include("la lista se actualiza sola")
    end

    it "does not refresh itself once every dispatch ended" do
      order_with("dispatched")
      order_with("failed")

      get orders_path

      expect(live_indicator).to be_empty
    end
  end

  it "makes each row open its order" do
    order = order_with("pending")

    get orders_path

    expect(rows.sole["data-row-link-url-value"]).to eq(order_path(order))
  end

  describe "pagination" do
    before { 27.times { |index| order_with("pending", created_at: index.minutes.ago) } }

    it "shows 25 orders per page" do
      get orders_path

      expect(rows.size).to eq(25)
      expect(response.body).to include("órdenes")
      expect(Nokogiri::HTML(response.body).css("nav.pagy a[href*='page=2']")).to be_present
    end

    it "shows the rest on the next page, keeping the filter" do
      get orders_path(status: "pending", page: 2)

      expect(rows.size).to eq(2)
      expect(Nokogiri::HTML(response.body).css("nav.pagy a[href]").map { |link| link["href"] }).to all(include("status=pending"))
    end

    it "serves a page past the end as an empty page" do
      get orders_path(page: 99)

      expect(response).to have_http_status(:ok)
      expect(rows).to be_empty
    end
  end

  it "explains how to create orders when there are none" do
    get orders_path

    expect(response.body).to include("No hay órdenes", "script/simulate_orders.rb")
  end
end
