Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

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
