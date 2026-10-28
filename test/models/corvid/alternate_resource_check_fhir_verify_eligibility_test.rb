# frozen_string_literal: true

require "test_helper"

# Issue #712 B1: AlternateResourceCheck#verify! must not persist a wrong answer when
# FhirAdapter would pick the wrong Coverage row.
class Corvid::AlternateResourceCheckFhirVerifyEligibilityTest < ActiveSupport::TestCase
  TENANT = "tnt_test"

  test "verify! leaves medicaid unchanged when FHIR bundle would wrongly deny from terminated coverage" do
    bundle = {
      "resourceType" => "Bundle",
      "entry" => [
        {
          "resource" => {
            "resourceType" => "Coverage",
            "id" => "cov_cancelled",
            "status" => "cancelled",
            "type" => { "coding" => [ { "code" => "MCDSC" } ] },
            "payor" => [ { "display" => "OLD TERMINATED PAYER" } ],
            "period" => { "start" => "2024-01-01", "end" => "2025-12-31" }
          }
        },
        {
          "resource" => {
            "resourceType" => "Coverage",
            "id" => "cov_active_open",
            "status" => "active",
            "type" => { "coding" => [ { "code" => "MCDSC" } ] },
            "payor" => [ { "display" => "CURRENT PAYER 712" } ],
            "period" => { "start" => "2026-01-01" }
          }
        }
      ]
    }
    inquiry = Date.new(2026, 9, 15)
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://example.test/fhir")

    with_tenant(TENANT) do
      travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
        referral = create_referral(patient_identifier: "pt_test_001")
        check = referral.alternate_resource_checks.find_or_create_by!(resource_type: "medicaid") do |row|
          row.status = "checking"
        end
        before = check.attributes.slice("status", "checked_at", "inquiry_date_of_service")

        adapter.stub(:fhir_search, bundle) do
          refute check.verify!(date_of_service: inquiry, adapter: adapter)
        end

        check.reload
        assert_equal before, check.attributes.slice("status", "checked_at", "inquiry_date_of_service"),
                     "verify! must not persist when adapter answer is undetermined (issue #712 B1)"
      end
    end
  end

  private

  def create_referral(patient_identifier:)
    kase = Corvid::Case.create!(
      patient_identifier: patient_identifier,
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "rf_#{SecureRandom.hex(4)}",
      facility_identifier: "fac_test"
    )
  end
end
