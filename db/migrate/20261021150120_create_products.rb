class CreateProducts < ActiveRecord::Migration[8.0]
  def change
    create_table :products do |t|
      t.string :name, null: false
      t.string :sku, null: false
      # Chilean pesos have no decimals, so prices are stored as integers.
      t.integer :price, null: false

      t.timestamps
    end
    add_index :products, :sku, unique: true
    add_check_constraint :products, "price > 0", name: "products_price_positive"
  end
end
