require "rails_helper"

RSpec.describe "Simulated stores panel", type: :request do
  let!(:las_condes) { create(:restaurant, name: "Niu Foods Las Condes", code: "LCON") }
  let!(:nunoa) { create(:restaurant, name: "Niu Foods Ñuñoa", code: "NUNO") }

  def page
    Nokogiri::HTML(response.body)
  end

  def receive(code, key, attempts: 1)
    StoreSimulator::Request.create!(store_code: code, idempotency_key: key, attempts: attempts,
                                    received_at: Time.current, payload: { "number" => key })
  end

  describe "GET /stores" do
    it "shows every store with its mode and what it received" do
      StoreSimulator::Mode.change!("NUNO", "down")
      receive("LCON", "LCON-000001", attempts: 3)
      StoreSimulator::Request.create!(store_code: "LCON", idempotency_key: "LCON-000002", attempts: 2)

      get stores_path

      expect(response).to have_http_status(:ok)
      lcon = page.css("#store_LCON").text.squish
      expect(lcon).to include("Niu Foods Las Condes", "Acepta", "LCON-000001", "3 solicitudes")
      expect(page.css("#store_LCON dd").map(&:text)).to eq(%w[1 5])
      expect(page.css("#store_NUNO").text.squish).to include("Caída", "Todavía no recibe órdenes")
    end

    it "marks the current mode and offers the others" do
      get stores_path

      buttons = page.css("#store_LCON form button")
      expect(buttons.map(&:text)).to eq(%w[Acepta Inestable Rechaza Caída])
      expect(buttons.select { |button| button["disabled"] }.map(&:text)).to eq(%w[Acepta])
      expect(buttons.first["aria-pressed"]).to eq("true")
    end

    it "shows the simulation notice on every page, without a link to itself here" do
      StoreSimulator::Mode.change!("NUNO", "reject")
      order = create(:order, restaurant: las_condes)

      [ orders_path, order_path(order), stores_path ].each do |path|
        get path
        expect(response.body).to include("Modo simulación", "Niu Foods Ñuñoa: Rechaza")
      end
      expect(response.body).not_to include("Cambiar en Tiendas")
    end

    it "shows no simulation notice while every store accepts every order" do
      StoreSimulator::Mode.change!("NUNO", "flaky:0")

      get stores_path

      expect(response.body).not_to include("Modo simulación")
    end

    it "keeps the last five receptions of each store, the newest first" do
      7.times { |index| receive("LCON", format("LCON-%06d", index), attempts: 1).update_columns(received_at: index.minutes.from_now) }
      receive("NUNO", "NUNO-000001")

      get stores_path

      expect(page.css("#store_LCON li span.font-mono").map(&:text)).to eq(%w[LCON-000006 LCON-000005 LCON-000004 LCON-000003 LCON-000002])
      expect(page.css("#store_NUNO li span.font-mono").map(&:text)).to eq(%w[NUNO-000001])
    end

    # The queries must not grow with the number of stores: the page refreshes
    # itself every few seconds.
    it "runs the same number of queries whatever the number of stores" do
      receive("LCON", "LCON-000001")
      receive("NUNO", "NUNO-000001")
      get stores_path
      with_two = count_queries { get stores_path }

      %w[PROV ANTO VALP].each do |code|
        create(:restaurant, code: code)
        StoreSimulator::Mode.change!(code, "down")
        receive(code, "#{code}-000001")
      end
      with_five = count_queries { get stores_path }

      expect(with_five).to eq(with_two)
    end

    it "is linked from the header" do
      get orders_path

      expect(page.css("header a").map(&:text)).to include("Tiendas")
    end
  end

  describe "PATCH /stores/:code" do
    it "changes how the store answers" do
      patch store_path("LCON"), params: { mode: "flaky:2" }

      expect(response).to redirect_to(stores_path)
      expect(StoreSimulator::Mode.current("LCON")).to eq("flaky:2")
      follow_redirect!
      expect(page.css("[role='status']").text).to include("Niu Foods Las Condes ahora responde en modo «Inestable»")
    end

    it "rejects a mode the panel does not offer" do
      patch store_path("LCON"), params: { mode: "flaky:50" }

      expect(StoreSimulator::Mode.current("LCON")).to eq("ok")
      follow_redirect!
      expect(page.css("[role='alert']").text).to include("Modo desconocido")
    end

    it "answers 404 for an unknown store" do
      patch store_path("XXXX"), params: { mode: "down" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
