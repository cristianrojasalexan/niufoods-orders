require "webmock/rspec"

# Specs must never reach real stores: every outgoing HTTP call has to be stubbed.
WebMock.disable_net_connect!(allow_localhost: false)
