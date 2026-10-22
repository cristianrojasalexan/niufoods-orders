module QueryCounter
  # SQL statements run by the block, leaving out schema lookups, transaction
  # statements and the query cache.
  def count_queries(&block)
    count = 0
    counter = lambda do |*, event|
      count += 1 unless event[:name].in?([ "SCHEMA", "TRANSACTION" ]) || event[:cached] || event[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end

RSpec.configure do |config|
  config.include QueryCounter, type: :request
end
