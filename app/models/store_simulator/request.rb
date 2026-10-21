module StoreSimulator
  # An order a store was asked to receive. attempts counts every request for
  # the same Idempotency-Key; received_at is set once, by the first request
  # the store accepted.
  class Request < ApplicationRecord
    scope :received, -> { where.not(received_at: nil) }
  end
end
