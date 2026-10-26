# frozen_string_literal: true

require "test_helper"

# Failing specs for open #639 / PR #688 findings (round 4+). Green only after fixes.
class Corvid::ClaimSubmissionMedicaidHoldOpenFindingsTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"
  PATIENT = "TEST,PATIENT 001"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup { travel_to RETRO_SCENARIO_TIME }
  teardown { travel_back }

  test "submit! still holds held claim when tenant context is tnt_other not the claim tenant" do
    with_tenant(TENANT) do
      claim = held_draft_claim!
      submit_calls = stub_submit_claim!

      with_tenant(OTHER_TENANT) do
        error = assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

        assert_includes(
          %w[inside_retroactive_window window_undetermined],
          error.reason
        )
      end

      assert_empty submit_calls
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier
    end
  end

  test "mark_submitted! still holds held claim when tenant context is tnt_other" do
    with_tenant(TENANT) do
      claim = held_draft_claim!

      with_tenant(OTHER_TENANT) do
        assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) do
          claim.mark_submitted!(claim_identifier: "CLM-TENANT-SPEC")
        end
      end

      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier
    end
  end

  test "submit! refuses held claim when tenant context is unset" do
    with_tenant(TENANT) do
      claim = held_draft_claim!
      submit_calls = stub_submit_claim!
      Corvid::TenantContext.reset!

      error = assert_raises(StandardError) { claim.submit! }

      refute_instance_of Corvid::ClaimSubmission::HeldForPendingMedicaid, error,
        "unset tenant must not evaluate hold against another tenant and send"
      assert_empty submit_calls
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
    end
  end

  test "never-submitted draft cannot reach paid through rejected intermediate status" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!

      claim.update!(status: "rejected")
      assert_equal "rejected", claim.reload.status
      assert_nil claim.submitted_at

      refute claim.update(status: "paid")
      assert claim.errors[:status].present? || claim.errors[:base].present?
      claim.reload
      assert_equal "rejected", claim.status
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier
    end
  end

  test "never-submitted draft cannot reach submitted through denied intermediate status" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!

      claim.update!(status: "denied")
      refute claim.update(status: "submitted", claim_identifier: "CLM-BYPASS-SPEC")
      claim.reload
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier
      refute_equal "submitted", claim.status
    end
  end

  test "never-submitted draft cannot reach paid through appealed intermediate status" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!

      claim.update!(status: "appealed")
      refute claim.update(status: "paid")
      claim.reload
      assert_nil claim.submitted_at
      refute_equal "paid", claim.status
    end
  end

  test "never-sent held claim cannot reach submitted by claim_identifier then status plain saves" do
    with_tenant(TENANT) do
      claim = held_draft_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) do
        claim.mark_submitted!(claim_identifier: "CLM-GATED-#{SecureRandom.hex(3)}")
      end
      claim.reload

      marker = "CLM-TWOSTEP-#{SecureRandom.hex(3)}"
      refute claim.update(claim_identifier: marker),
        "plain save must not persist claim_identifier on a never-sent claim"
      claim.reload
      assert_nil claim.claim_identifier
      assert_nil claim.submitted_at

      refute claim.update(status: "submitted"),
        "plain save must not move a never-sent claim into a sent status"
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier
    end
  end

  test "never-sent clear draft records claim_identifier and submitted_at through submit! and mark_submitted!" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
      claim.reload
      assert_equal "CLM-SPEC-001", claim.claim_identifier
      assert claim.submitted_at.present?

      mark_id = "CLM-MARK-#{SecureRandom.hex(3)}"
      claim2 = clear_to_submit_draft_claim!
      claim2.mark_submitted!(claim_identifier: mark_id)

      claim2.reload
      assert_equal mark_id, claim2.claim_identifier
      assert claim2.submitted_at.present?
    end
  end

  test "submit! raises UnsavedChanges for unsaved non-basis edits without calling adapter" do
    with_tenant(TENANT) do
      claim = clear_to_submit_draft_claim!
      submit_calls = stub_submit_claim!
      claim.billed_amount = 250.0

      error = assert_raises(StandardError) { claim.submit! }

      assert_equal "Corvid::ClaimSubmission::UnsavedChanges", error.class.name
      assert_match(/unsaved changes/i, error.message)
      assert_empty submit_calls
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
    end
  end

  private

  def held_draft_claim!
    referral = referral_at("fac_test", "REF-HOLD-#{SecureRandom.hex(3)}")
    authorize!(referral)
    medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
    medicaid.update!(
      status: "pending_enrollment",
      application_date: Date.new(2027, 3, 15),
      application_date_source: "staff_entry",
      medicaid_state_code: "XA",
      eligibility_group: "expansion_adult",
      eligibility_group_source: "staff_entry",
      eligibility_group_set_at: Time.current
    )
    claim = build_claim_for(referral, service_date: Date.new(2027, 2, 1))
    claim.save!
    claim
  end

  def clear_to_submit_draft_claim!
    referral = referral_at("fac_test", "REF-CLEAR-#{SecureRandom.hex(3)}")
    authorize!(referral)
    referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
    claim = build_claim_for(referral, service_date: Date.new(2027, 2, 1))
    claim.save!
    claim
  end

  def build_claim_for(referral, service_date:)
    Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT,
      facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier,
      referral_identifier: referral.referral_identifier,
      claim_type: "professional",
      service_date: service_date,
      billed_amount: 100.0,
      status: "draft"
    )
  end

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: PATIENT,
      facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase, referral_identifier: identifier, facility_identifier: facility
    )
  end

  def authorize!(referral)
    referral.submit!
    referral.begin_eligibility_review!
    referral.reload
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
    referral.pending_approval_by = "usr_other_approver"
    referral.approve_management!
    referral.reload
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.reload
    exhaust_alternate_resources!(referral)
    referral.complete_priority_assignment!
    referral.reload
    referral.authorize! if referral.may_authorize? && !referral.committee_review?
    referral.reload
  end

  def stub_submit_claim!
    calls = []
    Corvid.adapter.define_singleton_method(:submit_claim) do |data|
      calls << data
      { claim_identifier: "CLM-SPEC-001", status: "accepted" }
    end
    calls
  end
end
