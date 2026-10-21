class CreateRestaurants < ActiveRecord::Migration[8.0]
  def change
    create_table :restaurants do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.string :dispatch_url, null: false

      t.timestamps
    end
    add_index :restaurants, :code, unique: true
  end
end
