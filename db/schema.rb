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

ActiveRecord::Schema[8.1].define(version: 2026_10_21_194330) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "dispatch_attempts", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.integer "dispatch_cycle", null: false
    t.integer "attempt_number", null: false
    t.uuid "dispatch_token", null: false
    t.string "outcome", null: false
    t.integer "http_status"
    t.string "error_message"
    t.integer "duration_ms", null: false
    t.datetime "created_at", null: false
    t.index ["order_id"], name: "index_dispatch_attempts_on_order_id"
    t.check_constraint "outcome::text = ANY (ARRAY['success'::character varying, 'transient'::character varying, 'permanent'::character varying, 'stale'::character varying]::text[])", name: "dispatch_attempts_outcome_valid"
  end

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
    t.string "idempotency_key"
    t.string "request_fingerprint"
    t.string "dispatch_status", default: "pending", null: false
    t.integer "dispatch_cycle", default: 1, null: false
    t.integer "dispatch_attempts_count", default: 0, null: false
    t.datetime "next_dispatch_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.uuid "dispatch_token"
    t.datetime "dispatch_lease_expires_at"
    t.datetime "dispatched_at"
    t.string "last_dispatch_error"
    t.index ["created_at"], name: "index_orders_on_created_at"
    t.index ["dispatch_status", "next_dispatch_at"], name: "index_orders_on_dispatch_due", where: "((dispatch_status)::text = ANY ((ARRAY['pending'::character varying, 'dispatching'::character varying])::text[]))"
    t.index ["dispatch_status"], name: "index_orders_on_dispatch_status"
    t.index ["idempotency_key"], name: "index_orders_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["number"], name: "index_orders_on_number", unique: true
    t.index ["restaurant_id"], name: "index_orders_on_restaurant_id"
    t.check_constraint "dispatch_attempts_count >= 0", name: "orders_dispatch_attempts_non_negative"
    t.check_constraint "dispatch_status::text <> 'dispatched'::text OR dispatched_at IS NOT NULL", name: "orders_dispatched_has_timestamp"
    t.check_constraint "dispatch_status::text <> 'dispatching'::text OR dispatch_token IS NOT NULL AND dispatch_lease_expires_at IS NOT NULL", name: "orders_dispatching_has_lease"
    t.check_constraint "dispatch_status::text = ANY (ARRAY['pending'::character varying, 'dispatching'::character varying, 'dispatched'::character varying, 'failed'::character varying]::text[])", name: "orders_dispatch_status_valid"
    t.check_constraint "idempotency_key IS NULL OR request_fingerprint IS NOT NULL", name: "orders_idempotency_key_has_fingerprint"
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

  create_table "simulated_store_modes", primary_key: "store_code", id: :string, force: :cascade do |t|
    t.string "mode", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "simulated_store_requests", force: :cascade do |t|
    t.string "store_code", null: false
    t.string "idempotency_key", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "received_at"
    t.jsonb "payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["store_code", "idempotency_key"], name: "idx_on_store_code_idempotency_key_5886e0d50b", unique: true
    t.check_constraint "received_at IS NULL OR payload IS NOT NULL", name: "simulated_store_requests_receipt_has_payload"
  end

  add_foreign_key "dispatch_attempts", "orders"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "restaurants"
end
