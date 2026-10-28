# frozen_string_literal: true

require "test_helper"

# Issue #668 pin B: provenance entities reflect alternate-resource check state
# at decision (save) time, not rows reloaded after commit.
class Corvid::AlternateResourceProvenanceSnapshotTest < ActiveSupport::TestCase
  TENANT = "tnt_prov_snap"
  FACILITY = "fac_prov_snap"
  PATIENT = "pt-prov-snap"

  teardown do
    Corvid.reset_configuration!
  end

  test "authorize! provenance captures check state at decision before later writes in same host transaction" do
    captured = nil
    Corvid.configure { |c| c.on_provenance = ->(**attrs) { captured = attrs } }

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_ready_to_authorize!
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        decision_status = medicaid.status
        decision_checked_at = medicaid.checked_at

        ActiveRecord::Base.transaction do
          assert referral.authorize!
          medicaid.update!(status: "enrolled", checked_at: 2.hours.from_now)
        end

        refute_nil captured
        entity = captured[:entities].find { |e| e[:resource_type] == "medicaid" }
        refute_nil entity
        assert_equal decision_status, entity[:status],
          "provenance must snapshot checks at authorization, not post-commit reload"
        assert_equal decision_checked_at, entity[:checked_at]
      end
    end
  end

  test "claim submit! provenance captures check state at submission before later writes in same host transaction" do
    captured = nil
    Corvid.configure { |c| c.on_provenance = ->(**attrs) { captured = attrs } }

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at("fac_a", "REF-SNAP-CLAIM")
        authorize_referral!(referral)
        service_date = Date.new(2025, 6, 10)
        claim = build_claim(
          facility: "fac_a",
          referral_identifier: "REF-SNAP-CLAIM",
          patient: referral.case.patient_identifier,
          service_date: service_date
        )
        claim.save!

        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        decision_status = medicaid.status
        decision_checked_at = medicaid.checked_at

        ActiveRecord::Base.transaction do
          claim.submit!
          medicaid.update!(status: "enrolled", checked_at: 3.hours.from_now)
        end

        refute_nil captured
        entity = captured[:entities].find { |e| e[:resource_type] == "medicaid" }
        refute_nil entity
        assert_equal decision_status, entity[:status],
          "provenance must snapshot checks at claim submission, not post-commit reload"
        assert_equal decision_checked_at, entity[:checked_at]
      end
    end
  end

  private

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: PATIENT,
      facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: facility
    )
  end

  def build_claim(facility:, referral_identifier:, patient:, service_date:)
    Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT,
      facility_identifier: facility,
      patient_identifier: patient,
      referral_identifier: referral_identifier,
      claim_type: "professional",
      service_date: service_date,
      billed_amount: 100.0,
      status: "draft"
    )
  end

  def referral_ready_to_authorize!
    referral = referral_at(FACILITY, "REF-SNAP-AUTH")
    referral.submit!
    referral.begin_eligibility_review!
    checklist = referral.eligibility_checklist
    Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
      fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
      kwargs = {}
      kwargs[:source] = "test_fixture" if fields.key?(:source)
      kwargs[:by] = "usr_submitter" if fields.key?(:by)
      checklist.verify_item!(item, **kwargs)
    end
    referral.reload
    referral.request_management_approval!
    referral.pending_approval_by = "usr_other"
    referral.approve_management!
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.complete_priority_assignment!
    referral.update_column(:status, "priority_assignment")
    referral.reload
  end

  def authorize_referral!(referral)
    referral.submit! if referral.may_submit?
    referral.begin_eligibility_review! if referral.may_begin_eligibility_review?
    checklist = referral.eligibility_checklist
    Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
      fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
      kwargs = {}
      kwargs[:source] = "test_fixture" if fields.key?(:source)
      kwargs[:by] = "usr_submitter" if fields.key?(:by)
      checklist.verify_item!(item, **kwargs)
    end
    referral.reload
    referral.request_management_approval! if referral.may_request_management_approval?
    referral.pending_approval_by = "usr_other"
    referral.approve_management! if referral.may_approve_management?
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources! if referral.may_verify_alternate_resources?
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.complete_priority_assignment! if referral.may_complete_priority_assignment?
    referral.authorize! if referral.may_authorize?
    referral.reload
  end
end
