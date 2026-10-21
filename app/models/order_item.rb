class OrderItem < ApplicationRecord
  MAX_QUANTITY = 99

  belongs_to :order, inverse_of: :order_items
  belongs_to :product

  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY }
  validates :unit_price, numericality: { only_integer: true, greater_than: 0 }

  before_validation :calculate_subtotal

  # Called by the order before its own validation, so the item's price is
  # known when the order total is calculated. Returns nil while quantity or
  # price are missing; validations report those.
  def calculate_subtotal
    freeze_unit_price if new_record?
    self.subtotal = (unit_price * quantity if unit_price.is_a?(Integer) && quantity.is_a?(Integer))
  end

  private

  # Copies the current catalog price so later price changes do not affect the order.
  def freeze_unit_price
    self.unit_price ||= product&.price
  end
end
