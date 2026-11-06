Rails.application.routes.draw do
  # Owner login (Rails 8 authentication generator; there is no signup route on purpose)
  resource :session
  resources :passwords, param: :token

  get "up" => "rails/health#show", as: :rails_health_check

  # Agent surface: JSON-RPC over HTTP, Bearer API key
  post "/mcp", to: "mcp#handle"

  # App surface: Bearer API key
  namespace :api do
    namespace :v1 do
      post "send", to: "send#create"
      get "health", to: "health#show"
    end
  end

  # Owner UI (tailnet only)
  root "messages#index"
  resources :domains, only: %i[index new create show update] do
    post :probe, on: :member
  end
  resources :messages, only: %i[index show update]
  resources :blocked_senders, only: %i[index create destroy]
  get "messages/:message_id/attachments/:id", to: "attachments#show", as: :message_attachment
  resources :drafts, only: %i[index show new create update] do
    post :deliver, on: :member
  end
  resources :api_keys, only: %i[index new create destroy]
  resources :audit_events, only: :index
  resource :settings, only: %i[show update]
end
