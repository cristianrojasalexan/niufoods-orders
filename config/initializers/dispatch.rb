# Settings of the dispatch of orders to the stores (see docs/dispatch.md).
Rails.application.configure do
  dispatch = config.x.dispatch

  # Total attempts of one dispatch cycle, counted in PostgreSQL.
  dispatch.max_attempts_per_cycle = Integer(ENV.fetch("MAX_ATTEMPTS_PER_CYCLE", 5))
  # How long a worker holds an order. It must outlast the whole HTTP call, so
  # no other worker takes over an order whose delivery is still in progress.
  dispatch.lease_seconds = Integer(ENV.fetch("DISPATCH_LEASE_SECONDS", 60))
  # Wait before retrying a transient failure: base * 2**(attempt - 1), or
  # longer if the store asks for it with Retry-After, never above the cap.
  dispatch.retry_base_seconds = Integer(ENV.fetch("DISPATCH_RETRY_BASE_SECONDS", 10))
  dispatch.retry_max_seconds = Integer(ENV.fetch("DISPATCH_RETRY_MAX_SECONDS", 300))
  # Dispatch recovery (bin/dispatch_recovery): how often it runs, and how long
  # past next_dispatch_at a pending order may wait for its scheduled job
  # before the recovery enqueues it again.
  dispatch.recovery_interval_seconds = Integer(ENV.fetch("DISPATCH_RECOVERY_INTERVAL_SECONDS", 60))
  dispatch.recovery_grace_seconds = Integer(ENV.fetch("DISPATCH_RECOVERY_GRACE_SECONDS", 30))
  dispatch.open_timeout_seconds = 3
  dispatch.write_timeout_seconds = 10
  dispatch.read_timeout_seconds = 10
  # The HTTP timeouts limit each step, not the whole request; the delivery
  # as a whole is bounded by their sum (see Orders::Dispatcher#deliver).
  dispatch.delivery_deadline_seconds =
    dispatch.open_timeout_seconds + dispatch.write_timeout_seconds + dispatch.read_timeout_seconds

  # The lease covers the delivery plus loading the order and writing the
  # result, which may wait for the order lock. Twice the delivery deadline
  # leaves room for that.
  if dispatch.lease_seconds < 2 * dispatch.delivery_deadline_seconds
    raise ArgumentError, "DISPATCH_LEASE_SECONDS must be at least twice the delivery deadline " \
                         "(#{2 * dispatch.delivery_deadline_seconds}s)"
  end
end
