namespace :orders do
  desc "Enqueue dispatches that lost their job and fail expired leases without attempts left"
  task recover_dispatch: :environment do
    result = Orders::DispatchRecovery.call
    puts "Dispatch recovery: #{result.enqueued} enqueued, #{result.failed} failed"
  end
end
