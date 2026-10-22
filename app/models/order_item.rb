class OrderItem < ApplicationRecord
  MAX_QUANTITY = 99

  belongs_to :order, inverse_of: :order_items
  belongs_to :product

  # An item belongs to one order and one product for its whole life: moving
  # it would leave the total of the original order stale, and changing its
  # product would keep the price of the previous one. Rails raises if either
  # is assigned on a saved item; remove the item and add a new one instead.
  attr_readonly :order_id, :product_id

  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY }
  validates :unit_price, numericality: { only_integer: true, greater_than: 0 }

  before_validation :calculate_subtotal
  before_save :lock_order
  before_destroy :lock_order, unless: :destroyed_by_association
  after_save :refresh_order_total
  after_destroy :refresh_order_total, unless: :destroyed_by_association

  # Called by the order before its own validation, so the item's price is
  # known when the order total is calculated. Returns nil while quantity or
  # price are missing; validations report those.
  def calculate_subtotal
    freeze_unit_price if new_record?
    self.subtotal = (unit_price * quantity if unit_price.is_a?(Integer) && quantity.is_a?(Integer))
  end

  private

  # New items always take the current catalog price, whatever was assigned.
  # Once saved, the price is kept so later catalog changes do not affect it.
  def freeze_unit_price
    self.unit_price = product&.price
  end

  # Serializes item changes per order: a concurrent change to another item
  # of the same order waits until this transaction ends, so its total is
  # calculated from committed subtotals. The order is locked before the item
  # is written, the same order order.save! follows, which avoids deadlocks.
  # Locks with a plain query instead of order.lock! so the in-memory order
  # and its loaded items are not reloaded in the middle of a save.
  # Raises if the order was deleted while this change waited for the lock.
  def lock_order
    return unless order_id

    Order.where(id: order_id).lock.pluck(:id).presence ||
      raise(ActiveRecord::RecordNotFound.new("Order #{order_id} no longer exists", "Order", "id", order_id))
  end

  # Keeps the order total equal to the sum of its subtotals even when an item
  # is written on its own instead of through the order.
  def refresh_order_total
    order.refresh_total_amount!
  end
end
