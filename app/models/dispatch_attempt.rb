# One delivery attempt of an order to its store, kept for auditing.
class DispatchAttempt < ApplicationRecord
  belongs_to :order

  enum :outcome, { success: "success", transient: "transient", permanent: "permanent", stale: "stale" },
       validate: true
end
