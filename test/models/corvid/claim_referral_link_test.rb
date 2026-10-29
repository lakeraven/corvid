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
      record_delivered_fulfilment!(referral)

      claim.submit!

      assert_equal "submitted", claim.reload.status
      refute_nil claim.submitted_at
    end
  end

  test "linked draft claim cannot reach submitted without submit! or mark_submitted!" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-BYPASS-1")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-BYPASS-1", patient: patient)
      claim.save!

      assert_nil claim.submitted_at
      refute claim.update(status: "submitted")
      assert_predicate claim.errors[:status], :present?
      assert_equal "draft", claim.reload.status
      assert_nil claim.submitted_at
    end
  end

  test "linked draft claim cannot reach sent statuses without submission gate" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-BYPASS-2")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-BYPASS-2", patient: patient)
      claim.save!

      %w[accepted paid rejected denied appealed].each do |target_status|
        claim.status = target_status
        refute claim.save
        assert_predicate claim.errors[:status], :present?
        assert_equal "draft", claim.reload.status
      end
    end
  end

  test "linked error claim cannot reach sent statuses without submission gate" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-BYPASS-2B")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-BYPASS-2B", patient: patient)
      claim.save!
      claim.update_column(:status, "error")

      %w[submitted accepted paid rejected denied appealed].each do |target_status|
        refute claim.update(status: target_status)
        assert_predicate claim.errors[:status], :present?
        assert_equal "error", claim.reload.status
      end
    end
  end

  test "linked claim cannot reach submitted via plain save from any prior status" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-BYPASS-2C")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-BYPASS-2C", patient: patient)
      claim.save!
      claim.mark_submitted!(claim_identifier: "CLM-REJECT-RESUB")
      claim.mark_rejected!(reason_token: "tok_reject")
      assert_equal "rejected", claim.reload.status

      refute claim.update(status: "submitted")
      assert_predicate claim.errors[:status], :present?
      assert_equal "rejected", claim.reload.status
    end
  end

  test "linked draft cannot reach submitted when submitted_at was set without the gate" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-BYPASS-2D")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-BYPASS-2D", patient: patient)
      claim.save!
      claim.update_column(:submitted_at, 1.hour.ago)
      claim.reload

      refute claim.update(status: "submitted", claim_identifier: "CLM-FAKE-SUB")
      assert_predicate claim.errors[:status], :present?
      assert_equal "draft", claim.reload.status
    end
  end

  test "mark_submitted! from rejected re-runs authorization and alternate-resource gates" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        referral = referral_at("fac_a", "REF-RESUB-GATE")
        patient = referral.case.patient_identifier
        authorize!(referral)
        claim = build_claim(
          facility: "fac_a", referral_identifier: "REF-RESUB-GATE", patient: patient,
          service_date: Date.new(2025, 6, 15)
        )
        claim.save!
        claim.mark_submitted!(claim_identifier: "CLM-RESUB-1")
        claim.mark_rejected!(reason_token: "tok_resub")
        referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)

        Corvid.adapter.define_singleton_method(:verify_eligibility) { |_pid, _type| nil }

        assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) do
          claim.mark_submitted!(claim_identifier: "CLM-RESUB-2")
        end
        assert_equal "rejected", claim.reload.status
      end
    end
  end

  test "creating a linked claim already submitted remains allowed" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-BYPASS-3")
      patient = referral.case.patient_identifier
      authorize!(referral)

      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: "fac_a",
        patient_identifier: patient,
        referral_identifier: "REF-BYPASS-3",
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 100.0,
        status: "submitted"
      )

      assert claim.persisted?
      assert_equal referral.id, claim.prc_referral_id
      assert_equal "submitted", claim.status
    end
  end

  test "historical import of linked paid claim does not stamp submitted_at" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-IMPORT-PAID")
      patient = referral.case.patient_identifier

      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: "fac_a",
        patient_identifier: patient,
        referral_identifier: "REF-IMPORT-PAID",
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 100.0,
        status: "paid",
        paid_amount: 80.0
      )

      assert claim.persisted?
      assert_equal referral.id, claim.prc_referral_id
      assert_nil claim.reload.submitted_at
    end
  end

  test "status updates on claims already submitted keep working" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-BYPASS-4")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-BYPASS-4", patient: patient)
      claim.save!
      claim.mark_submitted!(claim_identifier: "CLM-BYPASS-4")

      claim.update!(status: "accepted")
      assert_equal "accepted", claim.reload.status

      claim.mark_paid!(paid_amount: 80.0)
      assert_equal "paid", claim.reload.status
    end
  end

  test "linked claim with nil submitted_at cannot reach submitted from error status" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-BYPASS-5")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-BYPASS-5", patient: patient)
      claim.save!

      claim.update!(status: "error")
      assert_equal "error", claim.reload.status
      assert_nil claim.submitted_at

      refute claim.update(status: "submitted")
      assert_predicate claim.errors[:status], :present?
      assert_equal "error", claim.reload.status
      assert_nil claim.submitted_at
    end
  end

  test "linked claim sent with adapter error status and claim_identifier can be accepted via check_status!" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        claim = linked_claim_sent_with_adapter_error!("REF-ERR-SENT-1", "CLM-ERR-SENT-1")

        Corvid.adapter.add_claim("CLM-ERR-SENT-1", { status: "accepted" })
        assert_nothing_raised { claim.check_status! }
        assert_equal "accepted", claim.reload.status
      end
    end
  end

  test "linked claim in adapter error status with claim_identifier can be paid via check_status!" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        claim = linked_claim_sent_with_adapter_error!("REF-ERR-SENT-2", "CLM-ERR-SENT-2")
        Corvid.adapter.add_claim("CLM-ERR-SENT-2", { status: "paid", paid_amount: 90.0 })

        assert_nothing_raised { claim.check_status! }
        assert_equal "paid", claim.reload.status
        assert_equal Money.from_amount(90, "USD"), claim.paid_amount
      end
    end
  end

  test "linked claim in adapter error status with claim_identifier can be denied via check_status!" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        claim = linked_claim_sent_with_adapter_error!("REF-ERR-SENT-3", "CLM-ERR-SENT-3")
        Corvid.adapter.add_claim("CLM-ERR-SENT-3", { status: "denied", denial_reason_codes: [ "CO-16" ] })

        assert_nothing_raised { claim.check_status! }
        claim.reload
        assert claim.denied?
        assert_equal [ "CO-16" ], claim.denial_reason_codes
      end
    end
  end

  test "RemittanceProcessor applies an 835 batch containing a linked claim sent with adapter error status" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        claim = linked_claim_sent_with_adapter_error!("REF-ERR-REMIT", "CLM-ERR-REMIT")

        result = Corvid::RemittanceProcessor.call([
          {
            remittance_identifier: "REM-ERR-SENT",
            payer_name: "Synthetic Payer",
            payment_date: Date.new(2025, 6, 20),
            total_paid: 75.0,
            line_items: [
              { claim_identifier: "CLM-ERR-REMIT", paid_amount: 75.0 }
            ]
          }
        ])

        assert_equal 1, result.paid
        assert_equal "paid", claim.reload.status
        assert_equal Money.from_amount(75, "USD"), claim.paid_amount
      end
    end
  end

  test "linked draft claim host-stamped as error with claim_identifier cannot be paid without submit gate" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-HOST-ERR-ID")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-HOST-ERR-ID", patient: patient)
      claim.save!

      refute claim.update(status: "error", claim_identifier: "HOST-IMPORTED-1")
      assert_includes claim.errors[:claim_identifier], Corvid::ClaimSubmission::SENT_MARKER_MESSAGE
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.claim_identifier
      assert_nil claim.submitted_at

      assert_raises(ActiveRecord::RecordInvalid) { claim.mark_paid!(paid_amount: 60.0) }
      claim.reload
      refute_equal "paid", claim.status
      refute claim.update(status: "paid", paid_amount: 60.0)
      assert_predicate claim.errors[:status], :present?
    end
  end

  test "linked draft claim host-stamped error with submitted_at cannot be adjudicated without submit gate" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-HOST-ERR-STAMP")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-HOST-ERR-STAMP", patient: patient)
      claim.save!

      refute claim.update(submitted_at: 1.hour.ago)
      assert_predicate claim.errors[:submitted_at], :present?
      assert_nil claim.reload.submitted_at

      refute claim.update(status: "error", submitted_at: 1.hour.ago)
      assert claim.errors[:submitted_at].present? || claim.errors[:claim_identifier].present?
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.submitted_at

      assert claim.update(status: "error")
      claim.reload
      assert_equal "error", claim.status
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier

      refute claim.update(submitted_at: 1.hour.ago)
      assert_predicate claim.errors[:submitted_at], :present?
      assert_nil claim.reload.submitted_at

      Corvid.adapter.add_claim("HOST-POLL-ONLY", { status: "paid", paid_amount: 25.0 })
      refute claim.update(claim_identifier: "HOST-POLL-ONLY")
      assert_predicate claim.errors[:claim_identifier], :present?
      assert_nil claim.reload.claim_identifier

      assert_raises(ActiveRecord::RecordInvalid) { claim.mark_paid!(paid_amount: 25.0) }
      refute_equal "paid", claim.reload.status

      refute claim.update(status: "error", claim_identifier: "HOST-POLL-ONLY", submitted_at: 1.hour.ago)
      assert claim.errors[:claim_identifier].present? || claim.errors[:submitted_at].present?
      claim.reload
      assert_nil claim.claim_identifier
      assert_nil claim.submitted_at

      claim.check_status!
      refute_equal "paid", claim.reload.status
    end
  end

  test "linked draft claim cannot set claim_identifier via plain save" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-NO-PLAIN-ID")
      patient = referral.case.patient_identifier
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-NO-PLAIN-ID", patient: patient)
      claim.save!

      refute claim.update(claim_identifier: "HOST-PLAIN-ID")
      assert_predicate claim.errors[:claim_identifier], :present?
      assert_nil claim.reload.claim_identifier
    end
  end

  test "linked error claim cannot set submitted_at via plain save" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-NO-PLAIN-STAMP")
      patient = referral.case.patient_identifier
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-NO-PLAIN-STAMP", patient: patient)
      claim.save!
      claim.update_column(:status, "error")

      refute claim.update(submitted_at: 1.hour.ago)
      assert_predicate claim.errors[:submitted_at], :present?
      assert_nil claim.reload.submitted_at
    end
  end

  test "never-sent linked claim on unauthorized referral cannot be paid after host error stamp" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-UNAUTH-HOST")
      patient = referral.case.patient_identifier
      assert_equal "draft", referral.status
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-UNAUTH-HOST", patient: patient)
      claim.save!

      refute claim.update(status: "paid")
      refute claim.update(status: "error", claim_identifier: "HOST-IMPORTED-1")
      assert_includes claim.errors[:claim_identifier], Corvid::ClaimSubmission::SENT_MARKER_MESSAGE
      claim.reload
      assert_equal "draft", claim.status
      assert_nil claim.claim_identifier

      assert_raises(ActiveRecord::RecordInvalid) { claim.mark_paid!(paid_amount: 100.0) }
      refute_equal "paid", claim.reload.status
    end
  end

  test "linked error claim with claim_identifier but no submitted_at can reach paid via mark_paid!" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-ERR-ID-ONLY")
      patient = referral.case.patient_identifier
      authorize!(referral)
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-ERR-ID-ONLY", patient: patient)
      claim.save!
      claim.update_columns(status: "error", claim_identifier: "CLM-ERR-ID-ONLY", submitted_at: nil)

      assert_nothing_raised { claim.mark_paid!(paid_amount: 60.0) }
      assert_equal "paid", claim.reload.status
    end
  end

  test "legacy linked claim submitted with nil submitted_at can be paid via mark_paid!" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-LEGACY-PAID")
      patient = referral.case.patient_identifier
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-LEGACY-PAID", patient: patient)
      claim.save!
      claim.update_columns(status: "submitted", claim_identifier: "CLM-LEGACY-PAID", submitted_at: nil)
      claim.reload
      assert_nil claim.submitted_at

      claim.mark_paid!(paid_amount: 75.0)
      assert_equal "paid", claim.reload.status
    end
  end

  test "legacy linked claim submitted with nil submitted_at can be polled via check_status!" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-LEGACY-POLL")
      patient = referral.case.patient_identifier
      claim = build_claim(facility: "fac_a", referral_identifier: "REF-LEGACY-POLL", patient: patient)
      claim.save!
      claim.update_columns(status: "submitted", claim_identifier: "CLM-LEGACY-POLL", submitted_at: nil)
      Corvid.adapter.add_claim("CLM-LEGACY-POLL", { status: "accepted" })

      claim.check_status!
      assert_equal "accepted", claim.reload.status
      assert_nil claim.submitted_at
    end
  end

  test "RemittanceProcessor pays legacy submitted claims with nil submitted_at without aborting the batch" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-REMIT-LEG")
      patient = referral.case.patient_identifier
      legacy = build_claim(facility: "fac_a", referral_identifier: "REF-REMIT-LEG", patient: patient)
      legacy.save!
      legacy.update_columns(
        status: "submitted", claim_identifier: "CLM-REMIT-LEG", submitted_at: nil, billed_amount_cents: 10_000
      )

      normal = build_claim(facility: "fac_a", referral_identifier: "REF-REMIT-LEG", patient: patient)
      normal.save!
      normal.update_columns(
        status: "submitted", claim_identifier: "CLM-REMIT-NORM", submitted_at: 2.days.ago, billed_amount_cents: 10_000
      )

      result = Corvid::RemittanceProcessor.call([
        {
          remittance_identifier: "REM-LEG",
          payer_name: "Test Payer",
          payment_date: Date.new(2025, 6, 20),
          total_paid: 200.0,
          line_items: [
            { claim_identifier: "CLM-REMIT-LEG", paid_amount: 80.0 },
            { claim_identifier: "CLM-REMIT-NORM", paid_amount: 90.0 }
          ]
        }
      ])

      assert_equal 2, result.paid
      assert_equal "paid", legacy.reload.status
      assert_equal "paid", normal.reload.status
    end
  end

  test "mark_submitted! refuses unauthorized referral like submit!" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "REF-MARK-GATE")
      exhaust_alternate_resources!(referral)
      assert_equal "draft", referral.reload.status

      claim = build_claim(
        facility: "fac_a", referral_identifier: "REF-MARK-GATE",
        patient: referral.case.patient_identifier
      )
      claim.save!

      verify_calls = []
      Corvid.adapter.define_singleton_method(:verify_eligibility) do |patient_identifier, resource_type|
        verify_calls << [ patient_identifier, resource_type ]
        { eligible: false }
      end

      error = assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) do
        claim.mark_submitted!(claim_identifier: "CLM-MARK-GATE")
      end
      assert_match(/not authorized/, error.message)
      assert_equal "draft", claim.reload.status
      assert_nil claim.submitted_at
      assert_empty verify_calls, "referral gate must run before payer re-verification"
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

  def build_claim(facility:, referral_identifier:, patient: nil, service_date: Date.current)
    Corvid::ClaimSubmission.new(
      tenant_identifier: TENANT, facility_identifier: facility,
      patient_identifier: patient || "pt_claim_#{SecureRandom.hex(3)}",
      referral_identifier: referral_identifier, claim_type: "professional",
      service_date: service_date, billed_amount: 100.0, status: "draft"
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
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.reload
    exhaust_alternate_resources!(referral)
    referral.update!(medical_priority: 1)
    referral.complete_priority_assignment!
    referral.reload
    # complete_priority_assignment lands on :authorized directly, or on
    # :committee_review when the referral requires a committee. Authorize only
    # from the former here; a committee decision is not something a test helper
    # should fabricate.
    referral.authorize! if referral.may_authorize? && !referral.committee_review?
    referral.reload
    record_delivered_fulfilment!(referral)
  end

  # Adapter returned an error status but assigned a claim identifier — treated as sent.
  def linked_claim_sent_with_adapter_error!(referral_identifier, claim_identifier)
    referral = referral_at("fac_a", referral_identifier)
    patient = referral.case.patient_identifier
    authorize!(referral)
    claim = build_claim(
      facility: "fac_a", referral_identifier: referral_identifier, patient: patient,
      service_date: Date.new(2025, 6, 15)
    )
    claim.save!
    claim.update_columns(
      status: "error",
      claim_identifier: claim_identifier,
      submitted_at: Time.zone.parse("2025-07-01 10:00:00 UTC")
    )
    claim.reload
  end
end
