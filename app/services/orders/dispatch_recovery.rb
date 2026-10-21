module Orders
  # Picks up the dispatches that lost their job: an order saved while Redis
  # was down, a retry that could not be scheduled, or a worker that died with
  # the order in its hands. Run periodically by bin/dispatch_recovery.
  #
  # 1. Orders whose lease expired after the last attempt of their cycle are
  #    marked as failed, and their token is cleared, so the late result of
  #    that worker is discarded as stale.
  # 2. Orders still due are enqueued again: pending ones past their
  #    next_dispatch_at by more than the grace period, and expired leases with
  #    attempts left. The grace period leaves room for the scheduled job.
  #
  # Enqueueing too early or twice is harmless: the claim checks again that
  # the order is due and has attempts left.
  class DispatchRecovery
    Result = Data.define(:failed, :enqueued)

    BATCH_SIZE = 500

    def self.call(settings: Rails.configuration.x.dispatch)
      new(settings).call
    end

    def initialize(settings)
      @settings = settings
    end

    def call
      failed = fail_exhausted_leases
      order_ids = due_order_ids
      DispatchOrderJob.perform_bulk(order_ids.map { |id| [ id ] }) if order_ids.any?
      Result.new(failed: failed, enqueued: order_ids.size)
    end

    private

    attr_reader :settings

    def fail_exhausted_leases
      max_attempts = settings.max_attempts_per_cycle
      expired_leases
        .where("dispatch_attempts_count >= ?", max_attempts)
        .update_all([ <<~SQL.squish, "lease expired during the last attempt (#{max_attempts}); delivery result unknown" ])
          dispatch_status = 'failed',
          dispatch_token = NULL,
          dispatch_lease_expires_at = NULL,
          last_dispatch_error = ?,
          updated_at = now()
        SQL
    end

    def due_order_ids
      overdue = Order.dispatch_pending
                     .where("next_dispatch_at <= now() - make_interval(secs => ?)", settings.recovery_grace_seconds)
      abandoned = expired_leases.where("dispatch_attempts_count < ?", settings.max_attempts_per_cycle)

      overdue.or(abandoned).order(:next_dispatch_at).limit(BATCH_SIZE).pluck(:id)
    end

    def expired_leases
      Order.dispatch_dispatching.where("dispatch_lease_expires_at < now()")
    end
  end
end
