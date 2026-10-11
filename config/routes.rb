# frozen_string_literal: true

Corvid::Engine.routes.draw do
  namespace :api do
    namespace :v1 do
      post "eligibility/check", to: "eligibility#check"
      post "indian_health_eligibility/inquire", to: "indian_health_eligibility#inquire"
      resources :decisions, only: [ :index, :show ]
    end
  end
end
