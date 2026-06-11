RailsConsoleAi::Engine.routes.draw do
  root to: 'sessions#index'
  resources :sessions, only: [:index, :show]

  resources :skills do
    member do
      post :approve
    end
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
    member do
      post :approve
    end
    collection do
      get :diff
    end
    resources :versions, only: [:index, :show], controller: 'memory_versions' do
      member do
        post :restore
      end
    end
  end

  resources :agents do
    member do
      post :approve
    end
    collection do
      get :diff
    end
    resources :versions, only: [:index, :show], controller: 'agent_versions' do
      member do
        post :restore
      end
    end
  end
end
