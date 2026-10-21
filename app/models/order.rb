class Order < ApplicationRecord
  NUMBER_FORMAT = "%<code>s-%<id>06d".freeze
  PHONE_FORMAT = /\A\+?\d{8,15}\z/

  belongs_to :restaurant
  has_many :order_items, dependent: :destroy, inverse_of: :order
  has_many :products, through: :order_items

  enum :order_type, { pickup: "pickup", delivery: "delivery" }, validate: true

  normalizes :customer_name, :delivery_address, with: ->(value) { value.strip.presence }
  normalizes :customer_phone, with: ->(value) { value.gsub(/[\s\-()]/, "") }

  validates :customer_name, presence: true
  validates :customer_phone, presence: true, format: { with: PHONE_FORMAT, allow_blank: true }
  validates :delivery_address, presence: true, if: :delivery?
  validates :order_items, length: { minimum: 1, message: :no_items }
  validates :total_amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :products_appear_once

  before_validation :calculate_total_amount
  before_create :assign_number

  private

  # The total is always derived from the items, never taken from the client.
  def calculate_total_amount
    self.total_amount = live_items.sum { |item| item.calculate_subtotal.to_i }
  end

  def products_appear_once
    product_ids = live_items.map(&:product_id)
    errors.add(:order_items, :duplicate_products) if product_ids.uniq.size != product_ids.size
  end

  # Reserves the primary key from its sequence before inserting, so the
  # number (e.g. LCON-000042) is unique and set in the same INSERT.
  def assign_number
    self.id ||= self.class.connection.select_value("SELECT nextval(pg_get_serial_sequence('orders', 'id'))")
    self.number ||= format(NUMBER_FORMAT, code: restaurant.code, id: id)
  end

  def live_items
    order_items.reject(&:marked_for_destruction?)
  end
end
