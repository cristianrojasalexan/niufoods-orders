require "sidekiq/web"

Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Sidekiq dashboard: queues, scheduled retries and processes. Open in
  # development; elsewhere only mounted behind SIDEKIQ_WEB_USER/PASSWORD.
  if Rails.env.development?
    mount Sidekiq::Web => "/sidekiq"
  elsif ENV["SIDEKIQ_WEB_USER"].present? && ENV["SIDEKIQ_WEB_PASSWORD"].present?
    Sidekiq::Web.use(Rack::Auth::Basic, "Sidekiq") do |user, password|
      ActiveSupport::SecurityUtils.secure_compare(user, ENV["SIDEKIQ_WEB_USER"]) &
        ActiveSupport::SecurityUtils.secure_compare(password, ENV["SIDEKIQ_WEB_PASSWORD"])
    end
    mount Sidekiq::Web => "/sidekiq"
  end

  # Dashboard to review the orders and retry a failed dispatch.
  root "orders#index"
  resources :orders, only: %i[index show] do
    post :redispatch, on: :member
  end

  # Simulated restaurant stores that receive the dispatched orders.
  scope "simulated_stores/:code", module: :store_simulator, as: :simulated_store,
                                  constraints: { code: /[A-Z]+/ }, defaults: { format: :json } do
    resources :orders, only: %i[index create]
    resource :mode, only: %i[show update]
  end

  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      resources :orders, only: %i[create show]
    end
  end
end
