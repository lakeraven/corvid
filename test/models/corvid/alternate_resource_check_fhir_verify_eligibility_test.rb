# frozen_string_literal: true

require "test_helper"

# Issue #712 B1 / PR #717 K1: AlternateResourceCheck#verify! must not persist a wrong answer when
# FhirAdapter would pick the wrong Coverage row, and must persist when selection agrees on enrollment.
class Corvid::AlternateResourceCheckFhirVerifyEligibilityTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  INQUIRY = Date.new(2026, 10, 15)
  VERIFY_PERSISTED_KEYS = %w[
    status checked_at inquiry_date_of_service policy_token
    coverage_start coverage_end renewal_date
  ].freeze

  test "verify! records enrolled when FHIR bundle selects applicable active medicaid coverage" do
    bundle = medicaid_selection_bundle(
      coverage_resource(
        id: "cov_ended",
        status: "active",
        payor: "ENDED PAYER",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      ),
      coverage_resource(
        id: "cov_secondary_coding",
        status: "active",
        codings: [ { "code" => "STATE-MEDICAID-PLAN" }, { "code" => "MCDSC" } ],
        payor: "CURRENT PAYER 717",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://example.test/fhir")

    with_tenant(TENANT) do
      travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
        check = medicaid_check_for("pt_test_001")

        adapter.stub(:fhir_search, bundle) do
          assert check.verify!(date_of_service: INQUIRY, adapter: adapter)
        end

        check.reload
        assert_equal "enrolled", check.status
        assert_equal INQUIRY, check.inquiry_date_of_service
        assert_equal Date.new(2026, 1, 1), check.coverage_start
        assert_equal Date.new(2026, 12, 31), check.coverage_end
        assert_nil check.renewal_date
        assert_not_nil check.checked_at
      end
    end
  end

  test "verify! leaves medicaid unchanged when cancelled and draft both apply on the inquiry date" do
    bundle = medicaid_selection_bundle(
      coverage_resource(
        id: "cov_cancelled",
        status: "cancelled",
        payor: "CANCELLED PAYER",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      ),
      coverage_resource(
        id: "cov_draft",
        status: "draft",
        payor: "DRAFT PAYER",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://example.test/fhir")

    with_tenant(TENANT) do
      travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
        check = medicaid_check_for("pt_test_001")
        before = check.attributes.slice(*VERIFY_PERSISTED_KEYS)

        adapter.stub(:fhir_search, bundle) do
          refute check.verify!(date_of_service: INQUIRY, adapter: adapter)
        end

        check.reload
        assert_equal before, check.attributes.slice(*VERIFY_PERSISTED_KEYS),
                     "verify! must not persist when adapter answer is undetermined (K1b)"
      end
    end
  end

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
        before = check.attributes.slice(*VERIFY_PERSISTED_KEYS)

        adapter.stub(:fhir_search, bundle) do
          refute check.verify!(date_of_service: inquiry, adapter: adapter)
        end

        check.reload
        assert_equal before, check.attributes.slice(*VERIFY_PERSISTED_KEYS),
                     "verify! must not persist when adapter answer is undetermined (issue #712 B1)"
      end
    end
  end

  private

  def medicaid_check_for(patient_identifier)
    referral = create_referral(patient_identifier: patient_identifier)
    referral.alternate_resource_checks.find_or_create_by!(resource_type: "medicaid") do |row|
      row.status = "checking"
    end
  end

  def medicaid_selection_bundle(*resources)
    {
      "resourceType" => "Bundle",
      "entry" => resources.map { |resource| { "resource" => resource } }
    }
  end

  def coverage_resource(id:, status:, payor:, codings: [ { "code" => "MCDSC" } ], period: nil)
    resource = {
      "resourceType" => "Coverage",
      "id" => id,
      "status" => status,
      "type" => { "coding" => codings },
      "payor" => [ { "display" => payor } ]
    }
    resource["period"] = period if period
    resource
  end

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
