RSpec.configure do |config|
  # freeze_time, travel_to and friends.
  config.include ActiveSupport::Testing::TimeHelpers
end
