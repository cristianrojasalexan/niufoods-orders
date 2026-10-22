class Order < ApplicationRecord
  NUMBER_FORMAT = "%<code>s-%<id>06d".freeze
  PHONE_FORMAT = /\A\+?\d{8,15}\z/

  belongs_to :restaurant
  has_many :order_items, dependent: :destroy, inverse_of: :order, autosave: true
  has_many :products, through: :order_items
  has_many :dispatch_attempts, -> { order(:id) }, dependent: :delete_all, inverse_of: :order

  enum :order_type, { pickup: "pickup", delivery: "delivery" }, validate: true
  # Written by Orders::Dispatcher with conditional SQL updates, never by
  # assigning it on a loaded order.
  enum :dispatch_status, { pending: "pending", dispatching: "dispatching", dispatched: "dispatched", failed: "failed" },
       prefix: :dispatch

  normalizes :customer_name, :delivery_address, with: ->(value) { value.strip.presence }
  normalizes :customer_phone, with: ->(value) { value.gsub(/[\s\-()]/, "") }

  validates :customer_name, presence: true
  validates :customer_phone, presence: true, format: { with: PHONE_FORMAT, allow_blank: true }
  validates :delivery_address, presence: true, if: :delivery?
  validates :order_items, length: { minimum: 1, message: :no_items }
  validates :total_amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :idempotency_key, length: { maximum: 255 }, allow_nil: true
  validate :products_appear_once

  before_validation :calculate_total_amount
  before_create :assign_number
  # Prepended so it runs before the dependent: :destroy cascade: the order is
  # locked before its items, the same order item changes follow.
  before_destroy :lock_row, prepend: true
  # While the order writes its items, an item it destroys does not check that
  # another one remains: the replacements are not written yet.
  around_save :track_saving
  # The total and the item count checked before validation come from the
  # items in memory, which may be stale if another process changed an item
  # since they were loaded. Once the order and its items are written, both
  # are checked again in the database. Declared after has_many, so it runs
  # after the items are saved.
  after_save :refresh_total_and_ensure_items

  # Recalculates the total from the subtotals stored in the database, with
  # the order row locked so no item change can commit between the sum and
  # the write. Runs within the transaction of the save that calls it.
  # Returns the number of items, read in the same query as the total.
  def refresh_total_amount!
    lock_row
    count, total = OrderItem.where(order_id: id).pick(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(subtotal), 0)"))
    update_column(:total_amount, total)
    count
  end

  def saving? = @saving == true

  private

  def track_saving
    @saving = true
    yield
  ensure
    @saving = false
  end

  # Only the final count matters, so replacing the last item in one save
  # (marking it for destruction and building another) is allowed.
  #
  # Raises RecordNotSaved rather than RecordInvalid: save (without !) turns
  # RecordInvalid into false and an ActiveRecord::Rollback, which an outer
  # transaction swallows and then commits the items already removed.
  # RecordNotSaved reaches the caller of save and save! alike, and rolls
  # back every enclosing transaction it goes through.
  def refresh_total_and_ensure_items
    return if refresh_total_amount!.positive?

    errors.add(:order_items, :no_items)
    raise ActiveRecord::RecordNotSaved.new("Order #{number} must keep at least one item", self)
  end

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

  def lock_row
    self.class.where(id: id).lock.pluck(:id)
  end

  def live_items
    order_items.reject(&:marked_for_destruction?)
  end
end
