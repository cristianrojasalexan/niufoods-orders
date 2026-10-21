require "sidekiq/testing"

# Jobs are pushed to an in-memory array instead of Redis; specs run them
# explicitly when they need to.
Sidekiq::Testing.fake!

RSpec.configure do |config|
  config.before { Sidekiq::Job.clear_all }
end
