class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders do |t|
      t.string :number, null: false
      t.references :restaurant, null: false, foreign_key: true
      t.string :order_type, null: false
      t.string :customer_name, null: false
      t.string :customer_phone, null: false
      t.string :delivery_address
      t.integer :total_amount, null: false

      t.timestamps
    end
    add_index :orders, :number, unique: true
    add_index :orders, :created_at

    add_check_constraint :orders, "order_type IN ('pickup', 'delivery')", name: "orders_order_type_valid"
    add_check_constraint :orders, "order_type <> 'delivery' OR delivery_address IS NOT NULL",
                         name: "orders_delivery_requires_address"
    add_check_constraint :orders, "total_amount >= 0", name: "orders_total_amount_non_negative"
  end
end
