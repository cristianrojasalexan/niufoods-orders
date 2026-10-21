class CreateOrderItems < ActiveRecord::Migration[8.0]
  def change
    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: true, index: false
      t.references :product, null: false, foreign_key: true
      t.integer :quantity, null: false
      # Price of the product when the order was created, so later catalog
      # changes never alter the total of an existing order.
      t.integer :unit_price, null: false
      t.integer :subtotal, null: false

      t.timestamps
    end
    add_index :order_items, [ :order_id, :product_id ], unique: true

    add_check_constraint :order_items, "quantity > 0", name: "order_items_quantity_positive"
    add_check_constraint :order_items, "unit_price > 0", name: "order_items_unit_price_positive"
    add_check_constraint :order_items, "subtotal = unit_price * quantity", name: "order_items_subtotal_consistent"
  end
end
