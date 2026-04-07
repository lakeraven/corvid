# frozen_string_literal: true

Rails.application.routes.draw do
  mount Corvid::Engine => "/corvid"
  get "up" => "rails/health#show", as: :rails_health_check
end
