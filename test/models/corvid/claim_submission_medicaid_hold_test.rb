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

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt-test-001",
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
