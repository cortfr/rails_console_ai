RailsConsoleAi::Engine.routes.draw do
  root to: 'sessions#index'
  resources :sessions, only: [:index, :show]

  resources :skills do
    collection do
      get :diff
    end
    resources :versions, only: [:index, :show], controller: 'skill_versions' do
      member do
        post :restore
      end
    end
  end

  resources :memories do
    collection do
      get :diff
    end
    resources :versions, only: [:index, :show], controller: 'memory_versions' do
      member do
        post :restore
      end
    end
  end
end
