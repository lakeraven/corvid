# frozen_string_literal: true

require "test_helper"

# Pins #submit! hold behaviour while a Medicaid alternate resource check is
# pending enrollment inside the retroactive coverage window (issue #639).
class Corvid::ClaimSubmissionMedicaidHoldTest < ActiveSupport::TestCase
  TENANT = "tnt_test"

  test "submit! raises HeldForPendingMedicaid when retro window covers service date" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      submit_calls = stub_submit_claim!

      error = assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_match(/medicaid/i, error.message)
      refute_match(/pt[-_]/i, error.message)
      assert_equal "draft", claim.reload.status
      assert_nil claim.submitted_at
      assert_empty submit_calls
    end
  end

  test "submit! holds when retro window is undetermined missing application_date" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      submit_calls = stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_empty submit_calls
      assert_equal "draft", claim.reload.status
    end
  end

  test "submit! holds when retro window is undetermined for unconfigured medicaid state" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "ZZ",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      submit_calls = stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_empty submit_calls
    end
  end

  test "submit! holds when retro window is undetermined for unknown eligibility group" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "unknown",
        service_date: Date.new(2027, 2, 1)
      )
      submit_calls = stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_empty submit_calls
    end
  end

  test "submit! holds when claim service_date is missing" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: nil
      )
      submit_calls = stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_empty submit_calls
    end
  end

  test "submit! proceeds when service_date is before earliest covered date" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2026, 9, 30)
      )
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
      assert_equal "submitted", claim.reload.status
    end
  end

  test "submit! proceeds without pending medicaid enrollment check" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-NO-PEND-#{SecureRandom.hex(3)}")
      authorize!(referral)
      referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
      claim = build_claim_for(referral, service_date: Date.new(2027, 2, 1))
      claim.save!
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
      assert_equal "submitted", claim.reload.status
    end
  end

  test "submit! proceeds when medicaid is enrolled not pending" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1),
        medicaid_status: "enrolled"
      )
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
    end
  end

  test "override_medicaid_hold! records override fields and allows submit!" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      submit_calls = stub_submit_claim!

      claim.override_medicaid_hold!(
        reason_token: "rt_medicaid_hold_override",
        by_identifier: "usr_billing_spec"
      )
      claim.reload
      assert_equal "rt_medicaid_hold_override", claim.medicaid_hold_override_reason_token
      assert_equal "usr_billing_spec", claim.medicaid_hold_override_by_identifier
      assert_not_nil claim.medicaid_hold_overridden_at

      claim.submit!

      assert_equal 1, submit_calls.size
      assert_equal "submitted", claim.reload.status
    end
  end

  test "override_medicaid_hold! rejects blank reason_token or by_identifier" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )

      assert_raises(ArgumentError) do
        claim.override_medicaid_hold!(reason_token: "", by_identifier: "usr_billing_spec")
      end
      assert_raises(ArgumentError) do
        claim.override_medicaid_hold!(reason_token: "rt_ok", by_identifier: "")
      end

      claim.reload
      assert_nil claim.medicaid_hold_override_reason_token
      assert_nil claim.medicaid_hold_override_by_identifier
      assert_nil claim.medicaid_hold_overridden_at
    end
  end

  test "submit! hold reason is inside_retroactive_window when retro window covers service date" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )

      error = assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_equal "inside_retroactive_window", error.reason
      assert_match(/inside_retroactive_window/, error.message)
      refute_match(/pt[-_]/i, error.message)
    end
  end

  test "submit! hold reason is window_undetermined when application_date is missing" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )

      error = assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_equal "window_undetermined", error.reason
      assert_match(/window_undetermined/, error.message)
    end
  end

  test "submit! holds when stored application_date is in the future treated as undetermined window" do
    with_tenant(TENANT) do
      claim, _, medicaid = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      future_date = Date.current + 1
      medicaid.update_columns(
        application_date: future_date,
        application_date_source: "staff_entry",
        medicaid_state_code: "XA"
      )
      submit_calls = stub_submit_claim!

      error = assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_equal "window_undetermined", error.reason
      assert_empty submit_calls
    end
  end

  test "mark_submitted! raises HeldForPendingMedicaid without changing the claim" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) do
        claim.mark_submitted!(claim_identifier: "CLM-MARK-SPEC")
      end

      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier
    end
  end

  test "submit! holds from pending medicaid on another referral for the same patient" do
    with_tenant(TENANT) do
      patient_id = "pt-mca-hold-cross-ref-#{SecureRandom.hex(2)}"
      seed_patient_pending_medicaid_on_referral!(
        patient_id: patient_id,
        referral_id: "REF-PEND-#{SecureRandom.hex(2)}",
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult"
      )
      billing_referral = authorized_referral_for_patient!(
        patient_id: patient_id,
        referral_id: "REF-BILL-#{SecureRandom.hex(2)}"
      )
      billing_referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
      claim = build_claim_for(billing_referral, service_date: Date.new(2027, 2, 1))
      claim.save!
      submit_calls = stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_empty submit_calls
    end
  end

  test "submit! holds from pending medicaid when claim has no linked referral" do
    with_tenant(TENANT) do
      patient_id = "pt-mca-hold-no-ref-#{SecureRandom.hex(2)}"
      seed_patient_pending_medicaid_on_referral!(
        patient_id: patient_id,
        referral_id: "REF-PEND-#{SecureRandom.hex(2)}",
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult"
      )
      claim = Corvid::ClaimSubmission.new(
        tenant_identifier: TENANT,
        facility_identifier: "fac_a",
        patient_identifier: patient_id,
        claim_type: "professional",
        service_date: Date.new(2027, 2, 1),
        billed_amount: 100.0,
        status: "draft"
      )
      claim.save!
      submit_calls = stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_empty submit_calls
    end
  end

  test "submit! ignores pending medicaid for a different patient" do
    with_tenant(TENANT) do
      seed_patient_pending_medicaid_on_referral!(
        patient_id: "pt-mca-hold-other-#{SecureRandom.hex(2)}",
        referral_id: "REF-OTHER-#{SecureRandom.hex(2)}",
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult"
      )
      billing_patient = "pt-mca-hold-bill-#{SecureRandom.hex(2)}"
      billing_referral = authorized_referral_for_patient!(
        patient_id: billing_patient,
        referral_id: "REF-BILL-#{SecureRandom.hex(2)}"
      )
      billing_referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
      claim = build_claim_for(billing_referral, service_date: Date.new(2027, 2, 1))
      claim.save!
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
    end
  end

  test "submit! ignores pending medicaid for the same patient under another tenant" do
    other_tenant = "tnt_mca_hold_iso_#{SecureRandom.hex(2)}"
    patient_id = "pt-mca-hold-tenant-#{SecureRandom.hex(2)}"
    with_tenant(other_tenant) do
      seed_patient_pending_medicaid_on_referral!(
        patient_id: patient_id,
        referral_id: "REF-ISO-#{SecureRandom.hex(2)}",
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult"
      )
    end
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-TENANT-#{SecureRandom.hex(2)}", patient_id: patient_id)
      authorize!(referral)
      referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
      claim = build_claim_for(referral, service_date: Date.new(2027, 2, 1))
      claim.save!
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
    end
  end

  test "medicaid hold override columns reject direct assignment outside override_medicaid_hold!" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )

      refute claim.update(
        medicaid_hold_override_reason_token: "rt_direct",
        medicaid_hold_override_by_identifier: "usr_direct",
        medicaid_hold_overridden_at: Time.current
      )
      assert claim.errors[:medicaid_hold_override_reason_token].present? ||
        claim.errors[:base].present?

      claim.reload
      assert_nil claim.medicaid_hold_override_reason_token
    end
  end

  test "partial medicaid hold override update is invalid without CheckViolation" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      claim.override_medicaid_hold!(
        reason_token: "rt_medicaid_hold_override",
        by_identifier: "usr_billing_spec"
      )

      assert_nothing_raised do
        refute claim.update(medicaid_hold_override_reason_token: nil)
      end
      assert claim.errors[:medicaid_hold_override_reason_token].present? ||
        claim.errors[:base].present?
      claim.reload
      assert_equal "rt_medicaid_hold_override", claim.medicaid_hold_override_reason_token
    end
  end

  test "override_medicaid_hold! sets overridden_at on the server not from caller params" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )

      frozen = Time.zone.parse("2027-04-01 12:00:00")
      travel_to frozen do
        claim.override_medicaid_hold!(
          reason_token: "rt_medicaid_hold_override",
          by_identifier: "usr_billing_spec"
        )
        assert_equal frozen, claim.reload.medicaid_hold_overridden_at
      end
    end
  end

  test "override_medicaid_hold! appends staff_review Determination on the claim" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )

      claim.override_medicaid_hold!(
        reason_token: "rt_hold_override_one",
        by_identifier: "usr_billing_a"
      )
      claim.override_medicaid_hold!(
        reason_token: "rt_hold_override_two",
        by_identifier: "usr_billing_b"
      )

      determinations = Corvid::Determination.where(
        determinable_type: claim.class.name,
        determinable_id: claim.id
      ).chronological.to_a
      assert_equal 2, determinations.size
      assert_equal %w[rt_hold_override_one rt_hold_override_two], determinations.map(&:reasons_token)
      determinations.each do |det|
        assert det.decision_method_staff_review?
        assert det.outcome_approved?
        assert det.determined_by_identifier.present?
      end
    end
  end

  test "medicaid hold override clears when service_date changes" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      claim.override_medicaid_hold!(
        reason_token: "rt_medicaid_hold_override",
        by_identifier: "usr_billing_spec"
      )

      claim.update!(service_date: Date.new(2027, 2, 2))
      claim.reload
      assert_nil claim.medicaid_hold_override_reason_token
      assert_nil claim.medicaid_hold_override_by_identifier
      assert_nil claim.medicaid_hold_overridden_at
    end
  end

  test "medicaid hold override clears when patient_identifier changes" do
    with_tenant(TENANT) do
      claim, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      claim.override_medicaid_hold!(
        reason_token: "rt_medicaid_hold_override",
        by_identifier: "usr_billing_spec"
      )

      claim.update!(patient_identifier: "pt-mca-hold-reassigned-#{SecureRandom.hex(2)}")
      claim.reload
      assert_nil claim.medicaid_hold_override_reason_token
    end
  end

  test "medicaid hold override clears when referral link changes" do
    with_tenant(TENANT) do
      claim, referral, = authorized_claim_with_pending_medicaid!(
        application_date: Date.new(2027, 3, 15),
        application_date_source: "staff_entry",
        medicaid_state_code: "XA",
        eligibility_group: "expansion_adult",
        service_date: Date.new(2027, 2, 1)
      )
      claim.override_medicaid_hold!(
        reason_token: "rt_medicaid_hold_override",
        by_identifier: "usr_billing_spec"
      )
      other = authorized_referral_for_patient!(
        patient_id: referral.case.patient_identifier,
        referral_id: "REF-SWITCH-#{SecureRandom.hex(2)}"
      )

      claim.update!(referral_identifier: other.referral_identifier, facility_identifier: other.facility_identifier)
      claim.reload
      assert_nil claim.medicaid_hold_override_reason_token
    end
  end

  test "referral authorization gate runs before medicaid hold" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-GATE-MCAID-#{SecureRandom.hex(3)}")
      medicaid = referral.alternate_resource_checks.find_or_create_by!(resource_type: "medicaid") do |check|
        check.status = "pending_enrollment"
      end
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
      submit_calls = stub_submit_claim!

      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }

      assert_empty submit_calls
    end
  end

  private

  def authorized_claim_with_pending_medicaid!(medicaid_status: "pending_enrollment", service_date:, **medicaid_attrs)
    referral = referral_at("fac_a", "REF-MCAID-#{SecureRandom.hex(3)}")
    authorize!(referral)
    medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
    medicaid.update!(
      status: medicaid_status,
      eligibility_group_source: "staff_entry",
      eligibility_group_set_at: Time.current,
      **medicaid_attrs
    )
    claim = build_claim_for(referral, service_date: service_date)
    claim.save!
    [ claim, referral, medicaid ]
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

  def referral_at(facility, identifier, patient_id: "pt-test-001")
    kase = Corvid::Case.create!(
      patient_identifier: patient_id,
      facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase, referral_identifier: identifier, facility_identifier: facility
    )
  end

  def seed_patient_pending_medicaid_on_referral!(patient_id:, referral_id:, **medicaid_attrs)
    kase = Corvid::Case.create!(
      patient_identifier: patient_id,
      facility_identifier: "fac_a"
    )
    referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: referral_id,
      facility_identifier: "fac_a"
    )
    medicaid = referral.alternate_resource_checks.find_or_create_by!(resource_type: "medicaid") do |check|
      check.status = "not_checked"
    end
    medicaid.update!(
      status: "pending_enrollment",
      eligibility_group_source: "staff_entry",
      eligibility_group_set_at: Time.current,
      **medicaid_attrs
    )
    referral
  end

  def authorized_referral_for_patient!(patient_id:, referral_id:)
    referral = referral_at("fac_a", referral_id, patient_id: patient_id)
    authorize!(referral)
    referral
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
