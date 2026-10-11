# frozen_string_literal: true

Corvid::Engine.routes.draw do
  namespace :api do
    namespace :v1 do
      post "eligibility/check", to: "eligibility#check"
      post "aian_exemption/determine", to: "aian_exemption#determine"
      resources :decisions, only: [ :index, :show ]
    end
  end
end
