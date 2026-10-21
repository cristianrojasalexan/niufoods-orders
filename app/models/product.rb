class Product < ApplicationRecord
  has_many :order_items, dependent: :restrict_with_error

  validates :name, presence: true
  validates :sku, presence: true, uniqueness: true
  validates :price, presence: true, numericality: { only_integer: true, greater_than: 0 }
end
