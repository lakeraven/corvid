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

  def test_verify_eligibility_nil_when_only_unknown_status_rows_exclude_inquiry
    repro = coverage_bundle(
      coverage_entry(
        id: "cov_entered_in_error_2020",
        status: "entered-in-error",
        payor: "STALE MEDICAID",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      )
    )

    with_bundle(repro) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY),
                 "entered-in-error Coverage whose period excludes the inquiry must be unknown (issue #712 review 1)"
    end
  end

  def test_verify_eligibility_nil_when_draft_coverage_period_excludes_inquiry
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_draft_excluded",
        status: "draft",
        payor: "DRAFT EXCLUDED PAYER",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY),
                 "draft with excluding bounds must be unknown when nothing applies (review 1)"
    end
  end

  def test_verify_eligibility_nil_when_absent_status_period_excludes_inquiry
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_no_status_excluded",
        status: nil,
        payor: "ABSENT STATUS PAYER",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      )
    )
    bundle["entry"].first["resource"].delete("status")

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY),
                 "Absent status with excluding bounds must be unknown when nothing applies (review 1)"
    end
  end

  def test_verify_eligibility_false_when_active_or_cancelled_period_excludes_inquiry
    [
      [ "active", "ACTIVE EXCLUDED" ],
      [ "cancelled", "CANCELLED EXCLUDED" ]
    ].each do |status, payor|
      bundle = coverage_bundle(
        coverage_entry(
          id: "cov_#{status}_excluded",
          status: status,
          payor: payor,
          period: { "start" => "2020-01-01", "end" => "2025-12-31" }
        )
      )

      with_bundle(bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
        assert result.is_a?(Hash), "#{status} with excluding bounds must answer eligible: false"
        refute result[:eligible], "#{status} excluding period must deny when no applicable row (review 1 pin)"
      end
    end
  end

  def test_verify_eligibility_excluding_active_denial_is_order_independent
    early = coverage_entry(
      id: "cov_early_excluded",
      status: "active",
      payor: "EARLY EXCLUDED PAYER",
      period: { "start" => "2020-01-01", "end" => "2025-12-31" }
    )
    late = coverage_entry(
      id: "cov_late_excluded",
      status: "active",
      payor: "LATE EXCLUDED PAYER",
      period: { "start" => "2018-01-01", "end" => "2019-12-31" }
    )

    results = [ coverage_bundle(early, late), coverage_bundle(late, early) ].map do |bundle|
      with_bundle(bundle) do
        @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
      end
    end

    results.each do |result|
      assert result.is_a?(Hash), "Two excluding active rows must still answer false, not nil"
      refute result[:eligible]
    end
    assert_equal results.first[:payer_name], results.last[:payer_name],
                 "Denial must come from latest period start among judged rows, not bundle order (review gap)"
    assert_equal "EARLY EXCLUDED PAYER", results.first[:payer_name]
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
        id: "cov_nil_start",
        status: "active",
        payor: "NIL START PAYER",
        period: { "end" => "2026-12-31" }
      ),
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
      assert_equal "LATEST START PAYER", result[:payer_name],
                   "Nil period start ranks earliest; latest real start wins (review gap)"
      assert_equal Date.new(2026, 6, 1), result[:coverage_start]
    end
  end

  def test_verify_eligibility_medicare_d_primary_type_does_not_match_medicare_a_or_b
    coverage = coverage_entry(
      id: "cov_medicare_d",
      status: "active",
      codings: [ { "code" => "medicare_d" }, { "code" => "MCRSC" } ],
      payor: "PART D PAYER",
      period: { "start" => "2026-01-01", "end" => "2026-12-31" }
    )
    bundle = coverage_bundle(coverage)

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicare_d", date_of_service: INQUIRY)
      assert result[:eligible], "medicare_d Coverage must match on primary type name (review 2)"
      assert_equal "PART D PAYER", result[:payer_name]

      assert_nil @adapter.verify_eligibility("pt_test_001", "medicare_a", date_of_service: INQUIRY),
                 "Shared MCRSC secondary coding must not match medicare_a (review 2)"
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicare_b", date_of_service: INQUIRY),
                 "Shared MCRSC secondary coding must not match medicare_b (review 2)"
    end
  end

  def test_verify_eligibility_mcrsc_primary_only_is_unknown_for_medicare_siblings
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_mcrsc_only_active",
        status: "active",
        codings: [ { "code" => "MCRSC" } ],
        payor: "AMBIGUOUS MEDICARE",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicare_a", date_of_service: INQUIRY),
                 "Primary shared ActCode without type name must stay unknown for medicare_a (review 2)"
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicare_b", date_of_service: INQUIRY),
                 "Primary shared ActCode without type name must stay unknown for medicare_b (review 2)"
    end
  end

  def test_verify_eligibility_medicaid_matches_primary_type_name_or_act_code
    [
      [ [ { "code" => "medicaid" } ], "TYPE NAME PAYER" ],
      [ [ { "code" => "MCDSC" } ], "ACT CODE PAYER" ]
    ].each do |codings, payor|
      bundle = coverage_bundle(
        coverage_entry(
          id: "cov_medicaid_#{payor.tr(' ', '_').downcase}",
          status: "active",
          codings: codings,
          payor: payor,
          period: { "start" => "2026-01-01", "end" => "2026-12-31" }
        )
      )

      with_bundle(bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
        assert result[:eligible], "medicaid inquiry must match Coverage typed #{codings.first['code']} (review 2)"
        assert_equal payor, result[:payer_name]
      end
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

  def test_verify_eligibility_shared_mcrsc_code_true_when_primary_type_name_matches
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_medicare_a_named",
        status: "active",
        codings: [ { "code" => "medicare_a" }, { "code" => "MCRSC" } ],
        payor: "ACTIVE MEDICARE A",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicare_a", date_of_service: INQUIRY)
      assert result[:eligible], "Primary medicare_a type name must verify when plan covers the inquiry (K2)"
      assert_equal "ACTIVE MEDICARE A", result[:payer_name]
    end
  end

  # Issue #712 review finding 1: present but unreadable period bounds are unknown, not open/closed.
  MALFORMED_PERIOD_BOUND_VALUES = [
    "2025-13-40",
    "ended",
    "not-a-date"
  ].freeze

  def test_verify_eligibility_nil_when_present_period_bound_is_not_a_valid_fhir_date
    covering = { "start" => "2026-01-01", "end" => "2026-12-31" }
    outside_month_inquiry = Date.new(2026, 9, 15)

    [
      [ "active", INQUIRY, :end, "2026-01-01" ],
      [ "active", INQUIRY, :start, "2026-12-31" ],
      [ "cancelled", INQUIRY, :end, "2026-01-01" ],
      [ "cancelled", INQUIRY, :start, "2026-12-31" ],
      [ "active", outside_month_inquiry, :end, "2026-01-01" ],
      [ "active", outside_month_inquiry, :start, "2026-09-30" ]
    ].each do |status, inquiry, bad_bound, good_value|
      MALFORMED_PERIOD_BOUND_VALUES.each do |bad_value|
        period = covering.merge(bad_bound == :end ? { "end" => bad_value } : { "start" => bad_value })
        period[bad_bound == :end ? "start" : "end"] = good_value

        bundle = coverage_bundle(
          coverage_entry(
            id: "cov_bad_#{status}_#{bad_bound}_#{bad_value.tr('-', '_')}",
            status: status,
            payor: "UNREADABLE BOUND PAYER",
            period: period
          )
        )

        with_bundle(bundle) do
          assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: inquiry),
                     "#{status} Coverage with unreadable period.#{bad_bound} #{bad_value.inspect} must be unknown (review 1)"
        end
      end
    end
  end

  def test_verify_eligibility_absent_period_bound_still_open_for_current_month_active
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_open_end",
        status: "active",
        payor: "OPEN END PAYER",
        period: { "start" => "2026-01-01" }
      )
    )

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
      assert result[:eligible], "Absent end bound must stay open (review 1 keep)"
      assert_nil result[:coverage_end]
    end
  end

  def test_verify_eligibility_false_when_well_formed_past_end_excludes_inquiry
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_past_end",
        status: "active",
        payor: "PAST END PAYER",
        period: { "start" => "2020-01-01", "end" => "2025-12-31" }
      )
    )

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
      refute result[:eligible], "Well-formed past end must still deny when nothing applies (review 1 keep)"
    end
  end

  # Issue #712 review finding 2: primary coding that names another resource type must not match via secondary ActCode.
  def test_verify_eligibility_nil_when_primary_coding_names_different_resource_type_with_requested_act_code
    Corvid::Adapters::FhirAdapter::COVERAGE_TYPE_MAP.each_key do |requested_type|
      other_type = (Corvid::Adapters::FhirAdapter::COVERAGE_TYPE_MAP.keys - [ requested_type ]).first
      act_code = Corvid::Adapters::FhirAdapter::COVERAGE_TYPE_MAP.fetch(requested_type)
      codings = [ { "code" => other_type }, { "code" => act_code } ]

      bundle = coverage_bundle(
        coverage_entry(
          id: "cov_wrong_primary_#{requested_type}",
          status: "active",
          codings: codings,
          payor: "WRONG PRIMARY #{requested_type.upcase}",
          period: { "start" => "2026-01-01", "end" => "2026-12-31" }
        )
      )

      with_bundle(bundle) do
        assert_nil @adapter.verify_eligibility("pt_test_001", requested_type, date_of_service: INQUIRY),
                   "Primary #{other_type} + #{act_code} must not match #{requested_type} (review 2)"
      end
    end
  end

  def test_verify_eligibility_nil_not_false_when_cancelled_primary_names_different_type_with_medicaid_act_code
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_tribal_medicaid_code",
        status: "cancelled",
        codings: [ { "code" => "tribal_program" }, { "code" => "MCDSC" } ],
        payor: "TRIBAL NOT MEDICAID",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
      assert_nil result,
                 "Cancelled tribal_program + MCDSC must not match or deny medicaid (review 2 repro)"
    end
  end

  def test_verify_eligibility_va_benefits_primary_with_medicaid_act_code_does_not_match_medicaid
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_va_medicaid_code",
        status: "active",
        codings: [ { "code" => "va_benefits" }, { "code" => "MCDSC" } ],
        payor: "VA NOT MEDICAID",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY),
                 "Primary va_benefits + secondary MCDSC must not verify medicaid (review 2 repro)"
    end
  end

  # Issue #712 review finding 3: ambiguous shared-ActCode-only rows must not participate in selection.
  def test_verify_eligibility_medicare_a_ignores_ambiguous_mcrsc_only_row_in_latest_start_selection
    unambiguous = coverage_entry(
      id: "cov_medicare_a_named",
      status: "active",
      codings: [ { "code" => "medicare_a" }, { "code" => "MCRSC" } ],
      payor: "UNAMBIGUOUS MEDICARE A",
      period: { "start" => "2026-01-01", "end" => "2026-12-31" }
    )
    ambiguous_late = coverage_entry(
      id: "cov_mcrsc_only_late",
      status: "active",
      codings: [ { "code" => "MCRSC" } ],
      payor: "AMBIGUOUS LATE",
      period: { "start" => "2026-06-01", "end" => "2026-12-31" }
    )
    ambiguous_early = coverage_entry(
      id: "cov_mcrsc_only_early",
      status: "active",
      codings: [ { "code" => "MCRSC" } ],
      payor: "AMBIGUOUS EARLY",
      period: { "start" => "2026-01-01", "end" => "2026-12-31" }
    )

    [
      coverage_bundle(unambiguous, ambiguous_late),
      coverage_bundle(ambiguous_late, unambiguous),
      coverage_bundle(unambiguous, ambiguous_early),
      coverage_bundle(ambiguous_early, unambiguous)
    ].each do |bundle|
      with_bundle(bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicare_a", date_of_service: INQUIRY)
        assert result.is_a?(Hash) && result[:eligible],
               "Unambiguous medicare_a row must win regardless of ambiguous MCRSC-only peer order (review 3); got #{result.inspect}"
        assert_equal "UNAMBIGUOUS MEDICARE A", result[:payer_name]
      end
    end
  end

  def test_verify_eligibility_nil_when_only_ambiguous_shared_act_code_rows_apply
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_mcrsc_only",
        status: "active",
        codings: [ { "code" => "MCRSC" } ],
        payor: "ONLY AMBIGUOUS",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" }
      )
    )

    with_bundle(bundle) do
      assert_nil @adapter.verify_eligibility("pt_test_001", "medicare_a", date_of_service: INQUIRY),
                 "Only ambiguous rows must stay unknown (review 3 keep)"
    end
  end

  # Issue #712 review finding 4: pin as_of on eligible:false answers from selected Coverage.
  def test_verify_eligibility_cancelled_denial_as_of_from_meta_last_updated
    last_updated = "2026-10-20T14:22:33Z"
    bundle = coverage_bundle(
      coverage_entry(
        id: "cov_cancelled_asof",
        status: "cancelled",
        payor: "CANCELLED ASOF PAYER",
        period: { "start" => "2026-01-01", "end" => "2026-12-31" },
        meta: { "lastUpdated" => last_updated }
      )
    )

    with_bundle(bundle) do
      result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
      refute result[:eligible]
      assert_equal Time.utc(2026, 10, 20, 14, 22, 33), result[:as_of],
                   "eligible:false answer must echo Coverage.meta.lastUpdated (review 4)"
    end
  end

  # Issue #712 review finding 5: nothing applies — active/cancelled exclusion wins over unknown-status rows.
  def test_verify_eligibility_false_from_excluded_active_when_unknown_status_row_has_later_start
    unknown_late = coverage_entry(
      id: "cov_draft_late_excluded",
      status: "draft",
      payor: "DRAFT LATE EXCLUDED",
      period: { "start" => "2026-11-01", "end" => "2026-12-31" }
    )
    active_excluded = coverage_entry(
      id: "cov_active_excluded",
      status: "active",
      payor: "ACTIVE EXCLUDED PAYER",
      period: { "start" => "2020-01-01", "end" => "2025-12-31" }
    )

    [ coverage_bundle(unknown_late, active_excluded), coverage_bundle(active_excluded, unknown_late) ].each do |bundle|
      with_bundle(bundle) do
        result = @adapter.verify_eligibility("pt_test_001", "medicaid", date_of_service: INQUIRY)
        assert result.is_a?(Hash), "Must not verify when nothing applies except excluded active/cancelled rows (review 5)"
        refute result[:eligible]
        assert_equal "ACTIVE EXCLUDED PAYER", result[:payer_name]
      end
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

  def coverage_entry(id:, status:, payor:, codings: [ { "code" => "MCDSC" } ], period: nil, meta: nil)
    resource = {
      "resourceType" => "Coverage",
      "id" => id,
      "status" => status,
      "type" => { "coding" => codings },
      "payor" => [ { "display" => payor } ]
    }
    resource["period"] = period if period
    resource["meta"] = meta if meta
    resource.compact
  end
end
