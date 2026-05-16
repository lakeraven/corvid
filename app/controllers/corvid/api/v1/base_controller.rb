# frozen_string_literal: true

module Corvid
  module Api
    module V1
      # Base class for corvid's headless JSON API. Subclasses inherit
      # tenant-context resolution + standard error rendering so each
      # endpoint stays focused on its own action.
      class BaseController < ActionController::API
        before_action :set_tenant_context

        rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
        rescue_from ActiveRecord::RecordInvalid, with: :render_unprocessable
        rescue_from Corvid::MissingTenantContextError, with: :render_missing_tenant

        private

        # Tenant comes in via header. The host application is responsible
        # for setting `X-Tenant-Identifier` (the deployment knows where
        # tenant identity comes from — JWT claim, subdomain, etc. — and
        # forwards it here).
        def set_tenant_context
          identifier = request.headers["X-Tenant-Identifier"].to_s
          if identifier.empty?
            render json: { error: "missing X-Tenant-Identifier header" }, status: :bad_request
            return false
          end
          Corvid::TenantContext.current_tenant_identifier = identifier
        end

        def render_not_found(exception)
          render json: { error: exception.message }, status: :not_found
        end

        def render_unprocessable(exception)
          render json: { error: exception.message, details: exception.record&.errors&.full_messages }, status: :unprocessable_entity
        end

        def render_missing_tenant(exception)
          render json: { error: exception.message }, status: :unprocessable_entity
        end
      end
    end
  end
end
