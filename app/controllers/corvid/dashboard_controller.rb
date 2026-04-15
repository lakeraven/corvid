# frozen_string_literal: true

module Corvid
  class DashboardController < ActionController::Base
    layout false

    def show
      @edi_adapter = Corvid.edi_adapter
      @edi_adapter_class = @edi_adapter&.class&.name || "Not configured"

      if @edi_adapter
        request = Lakeraven::Fhir::CoverageEligibilityRequest.new(
          patient_dfn: "demo-001",
          coverage_type: "medicaid",
          payer_id: "DEMO_MEDICAID",
          subscriber_id: "DEMO-SUB-001",
          subscriber_first_name: "Demo",
          subscriber_last_name: "Patient",
          subscriber_dob: "1985-06-15",
          provider_npi: "1234567890"
        )
        @eligibility_response = @edi_adapter.check_eligibility(request)
      end
    end
  end
end
