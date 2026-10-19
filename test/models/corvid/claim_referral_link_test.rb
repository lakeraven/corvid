# frozen_string_literal: true

require "test_helper"

# A claim has to be traceable to the referral it bills, and the link has to be
# the right one. These tests pin both the resolution rule and what #submit!
# does when a claim names a referral it cannot establish.
class Corvid::ClaimReferralLinkTest < ActiveSupport::TestCase
  TENANT = "tnt_claim_link"

  # --- resolution ----------------------------------------------------------

  test "a claim resolves to the referral sharing its facility and identifier" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-LINK-1")
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-LINK-1",
        patient: referral.case.patient_identifier)

      claim.save!

      assert_equal referral.id, claim.reload.prc_referral_id
    end
  end

  test "a claim does not resolve across facilities" do
    with_tenant(TENANT) do
      referral_at("fac_a", "REF-LINK-2")
      claim = build_claim(facility: "fac_b", referral_identifier: "REF-LINK-2")

      claim.save!

      assert_nil claim.reload.prc_referral_id,
        "the same identifier at another facility is a different referral"
    end
  end

  # PrcReferral's uniqueness is scoped to [tenant, facility]; PostgreSQL treats
  # NULLs as distinct in a unique index, so that scope does NOT stop two
  # referrals sharing an identifier while facility_identifier is NULL. Picking
  # either one would bill against a referral nobody chose.
  test "a claim refuses to resolve when more than one referral matches" do
    with_tenant(TENANT) do
      referral_at(nil, "REF-LINK-3")
      duplicate_referral_at(nil, "REF-LINK-3")
      claim = build_claim(facility: nil, referral_identifier: "REF-LINK-3")

      claim.save!

      assert_nil claim.reload.prc_referral_id,
        "an ambiguous match must not be guessed at"
    end
  end

  # --- the authorization gate ----------------------------------------------

  test "submit! refuses a claim whose referral is not authorized" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-GATE-1")
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-GATE-1",
        patient: referral.case.patient_identifier)
      claim.save!

      assert_equal "draft", referral.reload.status, "precondition"

      error = assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }
      assert_match(/not authorized/, error.message)
      assert_nil claim.reload.submitted_at,
        "a refused claim must not record a submission"
    end
  end

  test "submit! proceeds once the referral is authorized" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-GATE-2")
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-GATE-2",
        patient: referral.case.patient_identifier)
      claim.save!
      authorize!(referral)

      claim.submit!

      assert_equal "submitted", claim.reload.status
      refute_nil claim.submitted_at
    end
  end

  # referral_identifier is a loose external reference — a payer's or
  # provider's referral number with no PrcReferral behind it is ordinary
  # billing, not PRC billing (features/billing/claims_submission.feature bills
  # several). Those must keep working.
  test "submit! allows a claim naming a referral corvid does not know" do
    with_tenant(TENANT) do
      claim = build_claim(facility: "fac_a", referral_identifier: "EXTERNAL-REF-9000")
      claim.save!

      assert_nil claim.prc_referral_id, "precondition: nothing resolved"

      claim.submit!

      assert_equal "submitted", claim.reload.status
    end
  end

  test "submit! refuses a claim naming an ambiguous referral" do
    with_tenant(TENANT) do
      referral_at(nil, "REF-AMBIG-1")
      duplicate_referral_at(nil, "REF-AMBIG-1")
      claim = build_claim(facility: nil, referral_identifier: "REF-AMBIG-1")
      claim.save!

      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }
    end
  end

  test "submit! is unaffected for a claim that bills no referral" do
    with_tenant(TENANT) do
      claim = build_claim(facility: "fac_a", referral_identifier: nil)
      claim.save!

      claim.submit!

      assert_equal "submitted", claim.reload.status
    end
  end

  # --- the referral must be this patient's ---------------------------------
  #
  # A single match on facility and identifier says nothing about whose care it
  # authorized. Without a patient check, patient B's claim links to patient
  # A's referral and submit! then accepts A's authorization for B's bill.

  test "a claim does not resolve to another patient's referral" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-XPAT-1")
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-XPAT-1")
      refute_equal referral.case.patient_identifier, claim.patient_identifier, "precondition"

      claim.save!

      assert_nil claim.reload.prc_referral_id,
        "a referral for a different patient is not this claim's referral"
    end
  end

  test "submit! refuses a claim naming another patient's referral" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-XPAT-2")
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-XPAT-2")
      claim.save!

      error = assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }
      assert_match(/not this patient's/, error.message)
    end
  end

  test "a claim resolves when the referral is for the same patient" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-SAMEPT-1")
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-SAMEPT-1",
        patient: referral.case.patient_identifier)
      claim.save!

      assert_equal referral.id, claim.reload.prc_referral_id
    end
  end

  # --- an edited claim re-resolves -----------------------------------------
  #
  # Resolving only a blank link left an edited claim pointing at the referral
  # it used to name: submit! checked that one's authorization while
  # to_claim_data sent the new identifier to the payer.

  test "changing the referral identifier re-resolves the link" do
    with_tenant(TENANT) do
      authorized = referral_at("fac_a", "REF-EDIT-A")
      patient = authorized.case.patient_identifier
      authorize!(authorized)
      draft = referral_at_for_patient("fac_a", "REF-EDIT-B", patient)

      claim = build_claim(facility: "fac_a", referral_identifier: "REF-EDIT-A", patient: patient)
      claim.save!
      assert_equal authorized.id, claim.reload.prc_referral_id, "precondition"

      claim.update!(referral_identifier: "REF-EDIT-B")

      assert_equal draft.id, claim.reload.prc_referral_id,
        "the link must follow the identifier the payer will be sent"
      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }
    end
  end

  # --- the gate resolves a claim that reaches it unlinked -------------------

  test "submit! refuses an unlinked claim whose referral is not authorized" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-UNLINKED-1")
      patient = referral.case.patient_identifier
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-UNLINKED-1", patient: patient)
      claim.save!
      claim.update_column(:prc_referral_id, nil)
      claim.reload

      assert_nil claim.prc_referral_id, "precondition: reaches the gate unlinked"

      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) { claim.submit! }
    end
  end

  # --- the referral side ---------------------------------------------------

  test "destroying a referral leaves its claims standing, unlinked" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-NULLIFY-1")
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-NULLIFY-1",
        patient: referral.case.patient_identifier)
      claim.save!
      assert_equal referral.id, claim.reload.prc_referral_id

      referral.case.destroy!

      assert Corvid::ClaimSubmission.exists?(claim.id),
        "a claim has its own lifecycle with the payer and outlives the referral"
      assert_nil claim.reload.prc_referral_id
    end
  end

  private

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_#{identifier}_#{SecureRandom.hex(3)}", facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase, referral_identifier: identifier, facility_identifier: facility
    )
  end

  # A second referral sharing a tenant and identifier with a NULL facility.
  # Rails' uniqueness validation reads NULL = NULL and refuses this, but the
  # database does not: PostgreSQL treats NULLs as distinct in a unique index,
  # so the row is perfectly legal and arrives by import, migration or direct
  # SQL. Validation is skipped here to reproduce that, not to dodge a rule.
  def duplicate_referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_dup_#{identifier}_#{SecureRandom.hex(3)}", facility_identifier: facility
    )
    referral = Corvid::PrcReferral.new(
      case: kase, referral_identifier: identifier, facility_identifier: facility
    )
    referral.save!(validate: false)
    referral
  end

  def referral_at_for_patient(facility, identifier, patient)
    kase = Corvid::Case.create!(patient_identifier: patient, facility_identifier: facility)
    Corvid::PrcReferral.create!(
      case: kase, referral_identifier: identifier, facility_identifier: facility
    )
  end

  def build_claim(facility:, referral_identifier:, patient: nil)
    Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT, facility_identifier: facility,
      patient_identifier: patient || "pt_claim_#{SecureRandom.hex(3)}",
      referral_identifier: referral_identifier, claim_type: "professional",
      service_date: Date.current, billed_amount: 100.0, status: "draft"
    )
  end

  # Walks the real state machine rather than writing `status` directly, so the
  # gate is exercised against a referral authorized the way one actually is.
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
    referral.verify_alternate_resources!
    referral.reload
    referral.complete_priority_assignment!
    referral.reload
    # complete_priority_assignment lands on :authorized directly, or on
    # :committee_review when the referral requires a committee. Authorize only
    # from the former here; a committee decision is not something a test helper
    # should fabricate.
    referral.authorize! if referral.may_authorize? && !referral.committee_review?
    referral.reload
  end
end
