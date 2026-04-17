# frozen_string_literal: true

module Corvid
  # CMS-0057-F API usage metrics.
  #
  # Payers subject to 45 CFR 156.223 must publish annual public metrics for
  # each implemented API (Patient Access, Provider Access, Payer-to-Payer,
  # Prior Authorization). This service records each API call and aggregates
  # the required metrics into an annual report.
  #
  # Host apps call `.record!` from their mounted FHIR controllers. The PA
  # service does this automatically for its public methods.
  #
  # Reference: https://www.cms.gov/newsroom/fact-sheets/cms-interoperability-prior-authorization-final-rule-cms-0057-f
  class ApiMetricsService
    class << self
      # Log a single API call. Silently skips if no tenant context is set
      # so callers outside a tenant scope (e.g. background maintenance)
      # don't accidentally pollute metrics.
      #
      # Metrics recording MUST NOT fail a real API call. A DB hiccup or
      # validation miss on this table is an observability problem, not a
      # client-facing error, so we rescue and log rather than propagate.
      # The `!` in the name matches other Corvid services; it doesn't
      # imply the caller needs to handle exceptions.
      def record!(api:, endpoint:, patient_identifier: nil, app_identifier: nil, called_at: Time.current)
        tenant = Corvid::TenantContext.current_tenant_identifier
        return nil unless tenant

        Corvid::ApiCallLog.create!(
          tenant_identifier: tenant,
          facility_identifier: Corvid::TenantContext.current_facility_identifier,
          api_name: api.to_s,
          endpoint: endpoint.to_s,
          patient_identifier: patient_identifier,
          app_identifier: app_identifier,
          called_at: called_at
        )
      rescue => e
        Rails.logger.warn("ApiMetricsService.record! failed: #{Corvid.sanitize_phi(e.message)}")
        nil
      end

      # Aggregate metrics for a calendar year. Returns the shape CMS
      # expects in the annual public report.
      #
      #   {
      #     tenant: "tnt_foo",
      #     year: 2026,
      #     api: "pas" | nil,
      #     total_calls: 1234,
      #     unique_patients: 87,
      #     unique_apps: 12,
      #     calls_by_endpoint: { "submit" => 400, "read" => 800, "search" => 34 }
      #   }
      def annual_report(tenant:, year: Date.current.year, api: nil)
        Corvid::TenantContext.with_tenant(tenant) do
          scope = Corvid::ApiCallLog.in_year(year)
          scope = scope.for_api(api) if api

          {
            tenant: tenant,
            year: year,
            api: api,
            total_calls: scope.count,
            unique_patients: scope.where.not(patient_identifier: nil)
              .distinct.count(:patient_identifier),
            unique_apps: scope.where.not(app_identifier: nil)
              .distinct.count(:app_identifier),
            calls_by_endpoint: scope.group(:endpoint).count
          }
        end
      end
    end
  end
end
