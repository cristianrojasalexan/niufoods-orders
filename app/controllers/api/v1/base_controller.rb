module Api
  module V1
    # Base for the JSON API. ActionController::API skips the browser stack
    # (cookies, CSRF, views) that the dashboard controllers use.
    class BaseController < ActionController::API
    end
  end
end
