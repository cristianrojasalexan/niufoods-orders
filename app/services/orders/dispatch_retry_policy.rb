module Orders
  # How long to wait before retrying a delivery that failed with a transient
  # error: exponential backoff (base, 2·base, 4·base, ...), extended when the
  # store asks for more time with Retry-After, and never above the cap.
  #
  #   policy = Orders::DispatchRetryPolicy.new(base_seconds: 10, max_seconds: 300)
  #   policy.delay_for(1)                       # => 10
  #   policy.delay_for(3)                       # => 40
  #   policy.delay_for(1, retry_after: "120")   # => 120
  class DispatchRetryPolicy
    def self.from_settings(settings = Rails.configuration.x.dispatch)
      new(base_seconds: settings.retry_base_seconds, max_seconds: settings.retry_max_seconds)
    end

    def initialize(base_seconds:, max_seconds:)
      @base_seconds = base_seconds
      @max_seconds = max_seconds
    end

    # attempt_number is the attempt that just failed, starting at 1.
    # retry_after is the raw Retry-After header: seconds or an HTTP date.
    def delay_for(attempt_number, retry_after: nil)
      backoff = base_seconds * (2**(attempt_number - 1))
      [ backoff, retry_after_seconds(retry_after) ].compact.max.clamp(0, max_seconds)
    end

    private

    attr_reader :base_seconds, :max_seconds

    def retry_after_seconds(value)
      return if value.blank?
      return value.to_i if value.match?(/\A\d+\z/)

      (Time.httpdate(value) - Time.current).ceil.clamp(0..)
    rescue ArgumentError
      nil
    end
  end
end
