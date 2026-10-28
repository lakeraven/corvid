# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "active_support/all"
require "active_support/testing/time_helpers"
require "corvid/adapters/fhir_adapter"

# Issue #712 / PR #717: pins FhirAdapter#verify_eligibility coverage selection (K1, K2).
class Corvid::Adapters::FhirAdapterVerifyEligibilityCoverageSelectionTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  INQUIRY = Date.new(2026, 10, 15)
  FROZEN_AT = Time.utc(2026, 10, 27, 9, 0, 0)

  def setup
    @saved_time_zone = Time.zone
    Time.zone = "UTC"
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
  end

  def teardown
    Time.zone = @saved_time_zone
  end

  def test_verify_eligibility_matches_coverage_type_when_code_is_not_first_coding
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_state_plan",
        status: "active",
        codings: [ { "code" => "STATE-MEDICAID-PLAN" }, { "code" => "MCDSC" } ],
        payor: "SECONDARY CODING PAYER",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      ),
      coverage_entry(
        id: "cov_ended",
        status: "active",
        codings: [ { "code" => "MCDSC" } ],
        payor: "ENDED PAYER",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      )
    )

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
      assert result[:eligible],
             "Must enroll from applicable Coverage whose type coding includes MCDSC, not deny from ended row (K1a)"
      assert_equal "SECONDARY CODING PAYER", result[:payer_name]
    end
  end

  def test_verify_eligibility_nil_when_cancelled_and_draft_both_apply_to_inquiry
    bundle = dual_medicaid_bundle(
      coverage_entry(
        id: "cov_cancelled",
        status: "cancelled",
        payor: "CANCELLED PAYER",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      ),
      coverage_entry(
        id: "cov_draft",
        status: "draft",
        payor: "DRAFT PAYER",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY),
                 "Undetermined applicable Coverage must block a cancelled denial (K1b)"
    end
  end

  def test_verify_eligibility_nil_when_cancelled_without_period_and_draft_applies
    bundle = dual_medicaid_bundle(
      coverage_entry(id: "cov_cancelled", status: "cancelled", payor: "CANCELLED PAYER"),
      coverage_entry(
        id: "cov_draft",
        status: "draft",
        payor: "DRAFT PAYER",
        period: { "start" => "2026-10-01" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY),
                 "Draft applicable row must make the answer undetermined (K1c)"
    end
  end

  def test_verify_eligibility_nil_when_cancelled_without_period_disagrees_with_active
    bundle = dual_medicaid_bundle(
      coverage_entry(id: "cov_cancelled", status: "cancelled", payor: "CANCELLED PAYER"),
      coverage_entry(
        id: "cov_active",
        status: "active",
        payor: "ACTIVE PAYER",
        period: { "start" => "2026-01-01" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY),
                 "Disagreeing applicable Coverages must be undetermined (K1d)"
    end
  end

  def test_verify_eligibility_false_from_bounds_when_only_non_active_rows_have_ended_periods
    %w[entered-in-error].each do |status|
      bundle = coverage_bundle(
        coverage_entry(
          id: "cov_#{status.tr('-', '_')}",
          status: status,
          payor: "TERMINATED PAYER",
          period: { "start" => "2020-01-01", "end" => "2025-12-31" }
        )
      )

      with_bundle(bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
        assert result.is_a?(Hash),
               "#{status} with ended period and no applicable rows must answer eligible: false (K1e)"
        refute result[:eligible]
      end
    end

    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_no_status",
        status: nil,
        payor: "TERMINATED PAYER",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      )
    )
    bundle["entry"].first["resource"].delete("status")

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
      assert result.is_a?(Hash), "Absent status with ended period must answer eligible: false when nothing applies (K1e)"
      refute result[:eligible]
    end
  end

  def test_verify_eligibility_nil_when_non_active_status_has_covering_period
    [ nil, "entered-in-error" ].each do |status|
      resource = coverage_entry(
        id: "cov_covering",
        status: status,
        payor: "UNREADABLE PAYER",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
      resource.delete("status") if status.nil?
      bundle = coverage_bundle(resource)

      with_bundle(bundle) do
        assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY),
                   "Covering period with undetermined status must not answer false (K1e)"
      end
    end
  end

  def test_verify_eligibility_true_prefers_payer_from_latest_period_start_among_agreeing_active_rows
    bundle = dual_medicaid_bundle(
      coverage_entry(
        id: "cov_early",
        status: "active",
        payor: "EARLY START PAYER",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      ),
      coverage_entry(
        id: "cov_late",
        status: "active",
        payor: "LATEST START PAYER",
        period: { "start" => "2026-06-01", "end" => "2026-12-31" }
      )
    )

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
      assert result[:eligible], "Agreeing active Coverages must verify enrollment (K1f)"
      assert_equal "LATEST START PAYER", result[:payer_name]
      assert_equal Date.new(2026, 6, 1), result[:coverage_start]
    end
  end

  def test_verify_eligibility_shared_mcrsc_code_never_answers_false_for_ended_medicare_a
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_medicare_ended",
        status: "active",
        codings: [ { "code" => "MCRSC" } ],
        payor: "ENDED MEDICARE",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicare_a", date_of_service: INQUIRY),
                 "Shared MCRSC type must not fail closed when only an ended plan exists (K2)"
    end
  end

  def test_verify_eligibility_shared_ehcpol_code_never_answers_false_for_ended_liability_coverage
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_liability_ended",
        status: "active",
        codings: [ { "code" => "EHCPOL" } ],
        payor: "ENDED LIABILITY",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "liability_coverage", date_of_service: INQUIRY),
                 "Shared EHCPOL type must not fail closed when only an ended plan exists (K2)"
    end
  end

  def test_verify_eligibility_shared_mcrsc_code_true_when_active_plan_covers_inquiry
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_medicare_active",
        status: "active",
        codings: [ { "code" => "MCRSC" } ],
        payor: "ACTIVE MEDICARE",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicare_a", date_of_service: INQUIRY)
      assert result[:eligible], "Active shared-type Coverage must still verify when it covers the inquiry (K2)"
      assert_equal "ACTIVE MEDICARE", result[:payer_name]
    end
  end

  private

  def with_bundle(bundle, &block)
    travel_to(FROZEN_AT) do
      @adapter.stub(:fhir_search, bundle, &block)
    end
  end

  def coverage_bundle(*resources)
    {
      "resourceType" => "Bundle",
      "entry" => resources.map { |resource| { "resource" => resource } }
    }
  end

  def dual_medicaid_bundle(*resources)
    coverage_bundle(*resources)
  end

  def coverage_entry(id:, status:, payor:, codings: [ { "code" => "MCDSC" } ], period: nil)
    resource = {
      "resourceType" => "Coverage",
      "id" => id,
      "status" => status,
      "type" => { "coding" => codings },
      "payor" => [ { "display" => payor } ]
    }
    resource["period"] = period if period
    resource.compact
  end
end
