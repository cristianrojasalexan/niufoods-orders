# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_10_21_153511) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "order_items", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "product_id", null: false
    t.integer "quantity", null: false
    t.integer "unit_price", null: false
    t.integer "subtotal", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id", "product_id"], name: "index_order_items_on_order_id_and_product_id", unique: true
    t.index ["product_id"], name: "index_order_items_on_product_id"
    t.check_constraint "quantity > 0", name: "order_items_quantity_positive"
    t.check_constraint "subtotal = (unit_price * quantity)", name: "order_items_subtotal_consistent"
    t.check_constraint "unit_price > 0", name: "order_items_unit_price_positive"
  end

  create_table "orders", force: :cascade do |t|
    t.string "number", null: false
    t.bigint "restaurant_id", null: false
    t.string "order_type", null: false
    t.string "customer_name", null: false
    t.string "customer_phone", null: false
    t.string "delivery_address"
    t.integer "total_amount", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_orders_on_created_at"
    t.index ["number"], name: "index_orders_on_number", unique: true
    t.index ["restaurant_id"], name: "index_orders_on_restaurant_id"
    t.check_constraint "order_type::text <> 'delivery'::text OR delivery_address IS NOT NULL", name: "orders_delivery_requires_address"
    t.check_constraint "order_type::text = ANY (ARRAY['pickup'::character varying, 'delivery'::character varying]::text[])", name: "orders_order_type_valid"
    t.check_constraint "total_amount >= 0", name: "orders_total_amount_non_negative"
  end

  create_table "products", force: :cascade do |t|
    t.string "name", null: false
    t.string "sku", null: false
    t.integer "price", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sku"], name: "index_products_on_sku", unique: true
    t.check_constraint "price > 0", name: "products_price_positive"
  end

  create_table "restaurants", force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.string "dispatch_url", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_restaurants_on_code", unique: true
  end

  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "restaurants"
end
