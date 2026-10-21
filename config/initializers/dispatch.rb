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
  dispatch.open_timeout_seconds = 3
  dispatch.read_timeout_seconds = 10

  if dispatch.lease_seconds <= dispatch.open_timeout_seconds + dispatch.read_timeout_seconds
    raise ArgumentError, "DISPATCH_LEASE_SECONDS must be greater than the HTTP timeouts " \
                         "(#{dispatch.open_timeout_seconds + dispatch.read_timeout_seconds}s)"
  end
end
