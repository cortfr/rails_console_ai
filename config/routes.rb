RailsConsoleAi::Engine.routes.draw do
  root to: 'sessions#index'
  resources :sessions, only: [:index, :show]
end
