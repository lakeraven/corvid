# frozen_string_literal: true

require "test_helper"

# Issue #668 (C): authorization and claim gates re-verify stale checks first.
module Corvid
  class AlternateResourceReverificationGateTest < ActiveSupport::TestCase
    TENANT = "tnt_test"
    FACILITY = "fac_test"
    PATIENT = "pt-test-003"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
      @verify_calls = []
      install_verify_eligibility_stub(calls: @verify_calls, eligible: false)
    end

    test "verify_alternate_resources! re-verifies stale medicaid then proceeds when exhausted" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_in_alternate_resource_review
          create_all_determined_checks(referral)
          medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
          medicaid.update!(checked_at: 31.days.ago)

          @verify_calls.clear
          assert referral.verify_alternate_resources!
          assert_equal "priority_assignment", referral.status
          assert_includes @verify_calls.map { |c| c[1] }, "medicaid"
        end
      end
    end

    test "verify_alternate_resources! does not transition when stale check cannot be re-confirmed" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_in_alternate_resource_review
          create_all_determined_checks(referral)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)

          Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
            nil
          end

          refute referral.verify_alternate_resources!
          assert_equal "alternate_resource_review", referral.reload.status
        end
      end
    end

    test "complete_priority_assignment! re-verifies stale checks before authorizing" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_in_alternate_resource_review
          create_all_determined_checks(referral)
          assert referral.verify_alternate_resources!
          referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)

          referral.alternate_resource_checks.find_by!(resource_type: "medicare_a").update!(checked_at: 91.days.ago)
          @verify_calls.clear

          assert referral.complete_priority_assignment!
          assert_equal "authorized", referral.status
          assert_includes @verify_calls.map { |c| c[1] }, "medicare_a"
        end
      end
    end

    test "authorize! blocked when stale check re-verification fails" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_in_alternate_resource_review
          create_all_determined_checks(referral)
          assert referral.verify_alternate_resources!
          referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
          assert referral.complete_priority_assignment!
          referral.update_column(:status, "priority_assignment")

          referral.alternate_resource_checks.find_by!(resource_type: "private_insurance").update!(checked_at: 91.days.ago)
          install_verify_eligibility_stub do |_pid, _type, date_of_service:|
            { error: "unreadable" }
          end

          refute referral.authorize!
          assert_equal "priority_assignment", referral.reload.status
        end
      end
    end

    test "committee approval raises AuthorizationBlockedError when stale checks cannot be confirmed" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_in_alternate_resource_review
          create_all_determined_checks(referral)
          assert referral.verify_alternate_resources!
          referral.update!(medical_priority: 3, estimated_cost: 5_000)
          assert referral.complete_priority_assignment!
          assert_equal "committee_review", referral.status

          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)
          Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
            nil
          end

          review = CommitteeReview.create!(
            prc_referral: referral,
            committee_date: Date.current,
            decision: "approved",
            approved_amount: 5_000,
            facility_identifier: FACILITY,
            reviewer_identifier: "rv_test_001"
          )

          assert_raises(AuthorizationBlockedError) { review.apply_to_referral! }
          assert_equal "committee_review", referral.reload.status
        end
      end
    end

    test "submit! re-verifies stale medicaid then submits on first attempt" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_at("fac_a", "REF-STALE-CLAIM")
          authorize_referral!(referral)
          claim_service_date = Date.new(2025, 6, 15)
          stamp_alternate_resources_for_claim_service_date!(referral, claim_service_date)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)

          claim = build_claim(
            facility: "fac_a",
            referral_identifier: "REF-STALE-CLAIM",
            patient: referral.case.patient_identifier,
            service_date: claim_service_date
          )
          claim.save!

          submit_calls = 0
          Corvid.adapter.define_singleton_method(:submit_claim) do |_data|
            submit_calls += 1
            { claim_identifier: "CLM-1", status: "accepted" }
          end

          @verify_calls.clear
          claim.submit!

          assert_equal 1, submit_calls
          assert_equal "submitted", claim.reload.status
          assert_includes @verify_calls.map { |c| c[1] }, "medicaid"
        end
      end
    end

    test "submit! refuses claim when stale medicaid cannot be re-confirmed and retry stays refused" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_at("fac_a", "REF-UNCONF-CLAIM")
          authorize_referral!(referral)
          claim_service_date = Date.new(2025, 6, 15)
          stamp_alternate_resources_for_claim_service_date!(referral, claim_service_date)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)

          claim = build_claim(
            facility: "fac_a",
            referral_identifier: "REF-UNCONF-CLAIM",
            patient: referral.case.patient_identifier,
            service_date: claim_service_date
          )
          claim.save!

          Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
            nil
          end
          submit_calls = 0
          Corvid.adapter.define_singleton_method(:submit_claim) do |_data|
            submit_calls += 1
            { claim_identifier: "CLM-2", status: "accepted" }
          end

          2.times do
            assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) { claim.submit! }
            assert_equal "draft", claim.reload.status
          end
          assert_equal 0, submit_calls
        end
      end
    end

    test "mark_submitted! re-verifies stale medicaid then records submission on first call" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_at("fac_a", "REF-MARK-REVER")
          authorize_referral!(referral)
          claim_service_date = Date.new(2025, 6, 15)
          stamp_alternate_resources_for_claim_service_date!(referral, claim_service_date)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)

          claim = build_claim(
            facility: "fac_a",
            referral_identifier: "REF-MARK-REVER",
            patient: referral.case.patient_identifier,
            service_date: claim_service_date
          )
          claim.save!

          @verify_calls.clear
          claim.mark_submitted!(claim_identifier: "EXT-CLM-REVER")

          assert_equal "submitted", claim.reload.status
          assert_equal "EXT-CLM-REVER", claim.claim_identifier
          assert_includes @verify_calls.map { |c| c[1] }, "medicaid"
        end
      end
    end

    test "submit! refuses claim with nil service_date" do
      with_tenant(TENANT) do
        referral = referral_at("fac_a", "REF-NIL-DOS")
        authorize_referral!(referral)
        claim = build_claim(
          facility: "fac_a",
          referral_identifier: "REF-NIL-DOS",
          patient: referral.case.patient_identifier,
          service_date: nil
        )
        claim.save!

        assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) { claim.submit! }
      end
    end

    test "mark_submitted! refuses when stale medicaid cannot be re-confirmed" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_at("fac_a", "REF-MARK-SUB")
          authorize_referral!(referral)
          claim_service_date = Date.new(2025, 6, 15)
          stamp_alternate_resources_for_claim_service_date!(referral, claim_service_date)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)

          claim = build_claim(
            facility: "fac_a",
            referral_identifier: "REF-MARK-SUB",
            patient: referral.case.patient_identifier,
            service_date: claim_service_date
          )
          claim.save!

          install_verify_eligibility_stub do |_pid, _type, date_of_service:|
            raise "payer down"
          end

          assert_raises(Corvid::ClaimSubmission::AlternateResourcesNotCurrent) do
            claim.mark_submitted!(claim_identifier: "EXT-CLM-001")
          end
          assert_equal "draft", claim.reload.status
        end
      end
    end

    test "authorization_blockers names medicaid not current when stale for authorization date" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_in_alternate_resource_review
          create_all_determined_checks(referral)
          assert referral.verify_alternate_resources!
          referral.update!(medical_priority: 3, estimated_cost: 5_000)
          assert referral.complete_priority_assignment!
          assert_equal "committee_review", referral.status

          exhaust_alternate_resources!(referral, date_of_service: Date.current, as_of: Time.current)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)
          install_verify_eligibility_stub do |_pid, _type, date_of_service:|
            raise "unreadable"
          end

          blockers = referral.authorization_blockers
          assert_includes blockers, "medicaid: not current"
          refute_equal [ "referral: committee_review" ], blockers

          committee_blockers = referral.committee_approval_blockers
          assert_includes committee_blockers, "medicaid: not current"
          refute_equal [ "referral: committee_review" ], committee_blockers
        end
      end
    end

    test "committee apply_to_referral! surfaces medicaid not current when re-verification fails" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_in_alternate_resource_review
          create_all_determined_checks(referral)
          assert referral.verify_alternate_resources!
          referral.update!(medical_priority: 3, estimated_cost: 5_000)
          assert referral.complete_priority_assignment!
          exhaust_alternate_resources!(referral, date_of_service: Date.current, as_of: Time.current)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)
          Corvid.adapter.define_singleton_method(:verify_eligibility) do |_pid, _type, date_of_service: nil|
            nil
          end

          review = CommitteeReview.create!(
            prc_referral: referral,
            committee_date: Date.current,
            decision: "approved",
            approved_amount: 5_000,
            facility_identifier: FACILITY,
            reviewer_identifier: "rv_test_002"
          )

          error = assert_raises(AuthorizationBlockedError) { review.apply_to_referral! }
          assert_includes error.blockers, "medicaid: not current"
          assert_equal "committee_review", referral.reload.status
        end
      end
    end

    test "committee apply_to_referral! on cancelled referral makes no payer calls and leaves checks unchanged" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral, review = committee_approved_review_with_stale_medicaid
          referral.cancel!
          before = alternate_resource_check_snapshot(referral)

          @verify_calls.clear
          error = assert_raises(AuthorizationBlockedError) { review.apply_to_referral! }
          assert_includes error.blockers, "referral: cancelled"

          assert_empty @verify_calls
          assert_equal before, alternate_resource_check_snapshot(referral.reload)
          assert_equal "cancelled", referral.status
        end
      end
    end

    test "committee apply_to_referral! on denied referral makes no payer calls and leaves checks unchanged" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral, review = committee_approved_review_with_stale_medicaid
          referral.mark_denied!
          before = alternate_resource_check_snapshot(referral)

          @verify_calls.clear
          error = assert_raises(AuthorizationBlockedError) { review.apply_to_referral! }
          assert_includes error.blockers, "referral: denied"

          assert_empty @verify_calls
          assert_equal before, alternate_resource_check_snapshot(referral.reload)
          assert_equal "denied", referral.status
        end
      end
    end

    test "committee apply_to_referral! on draft referral makes no payer calls and leaves checks unchanged" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = create_referral_record
          create_all_determined_checks(referral)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)
          review = CommitteeReview.create!(
            prc_referral: referral,
            committee_date: Date.current,
            decision: "approved",
            approved_amount: 5_000,
            facility_identifier: FACILITY,
            reviewer_identifier: "rv_draft_gate"
          )
          before = alternate_resource_check_snapshot(referral)

          @verify_calls.clear
          error = assert_raises(AuthorizationBlockedError) { review.apply_to_referral! }
          assert_includes error.blockers, "referral: draft"

          assert_empty @verify_calls
          assert_equal before, alternate_resource_check_snapshot(referral.reload)
          assert_equal "draft", referral.status
        end
      end
    end

    test "sync_decision on cancelled referral makes no payer calls and leaves checks unchanged" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral, review = committee_approved_review_with_stale_medicaid
          referral.cancel!
          before = alternate_resource_check_snapshot(referral)

          recording = sync_recording_adapter
          @verify_calls.clear
          result = CommitteeReviewSyncService.sync_decision(review, adapter: recording)

          refute result[:success]
          assert result[:blocked]
          assert_includes result[:blockers], "referral: cancelled"
          assert_empty recording.verify_calls
          assert_empty @verify_calls
          assert_equal before, alternate_resource_check_snapshot(referral.reload)
        end
      end
    end

    test "sync_decision on denied referral makes no payer calls and leaves checks unchanged" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral, review = committee_approved_review_with_stale_medicaid
          referral.mark_denied!
          before = alternate_resource_check_snapshot(referral)

          recording = sync_recording_adapter
          @verify_calls.clear
          result = CommitteeReviewSyncService.sync_decision(review, adapter: recording)

          refute result[:success]
          assert result[:blocked]
          assert_includes result[:blockers], "referral: denied"
          assert_empty recording.verify_calls
          assert_empty @verify_calls
          assert_equal before, alternate_resource_check_snapshot(referral.reload)
        end
      end
    end

    test "sync_decision on draft referral makes no payer calls and leaves checks unchanged" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = create_referral_record
          create_all_determined_checks(referral)
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)
          review = CommitteeReview.create!(
            prc_referral: referral,
            committee_date: Date.current,
            decision: "approved",
            approved_amount: 5_000,
            facility_identifier: FACILITY,
            reviewer_identifier: "rv_sync_draft"
          )
          before = alternate_resource_check_snapshot(referral)

          recording = sync_recording_adapter
          @verify_calls.clear
          result = CommitteeReviewSyncService.sync_decision(review, adapter: recording)

          refute result[:success]
          assert result[:blocked]
          assert_includes result[:blockers], "referral: draft"
          assert_empty recording.verify_calls
          assert_empty @verify_calls
          assert_equal before, alternate_resource_check_snapshot(referral.reload)
        end
      end
    end

    test "verify_alternate_resources! on draft referral makes no payer calls" do
      with_tenant(TENANT) do
        referral = create_referral_record
        create_all_determined_checks(referral)
        before = alternate_resource_check_snapshot(referral)

        @verify_calls.clear
        refute referral.verify_alternate_resources!

        assert_empty @verify_calls
        assert_equal before, alternate_resource_check_snapshot(referral.reload)
        assert_equal "draft", referral.status
      end
    end

    test "authorize! on authorized referral makes no payer calls and leaves checks unchanged" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_in_alternate_resource_review
          create_all_determined_checks(referral)
          assert referral.verify_alternate_resources!
          referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
          assert referral.complete_priority_assignment!
          assert_equal "authorized", referral.status
          referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)
          before = alternate_resource_check_snapshot(referral)

          @verify_calls.clear
          refute referral.authorize!

          assert_empty @verify_calls
          assert_equal before, alternate_resource_check_snapshot(referral.reload)
          assert_equal "authorized", referral.status
        end
      end
    end

    test "complete_priority_assignment! from authorized state makes no payer calls" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determined_checks(referral)
        assert referral.verify_alternate_resources!
        referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
        assert referral.complete_priority_assignment!
        assert_equal "authorized", referral.status
        before = alternate_resource_check_snapshot(referral)

        @verify_calls.clear
        refute referral.may_complete_priority_assignment?
        refute referral.complete_priority_assignment!

        assert_empty @verify_calls
        assert_equal before, alternate_resource_check_snapshot(referral.reload)
      end
    end

    test "submit! does not re-verify 45-day-old va_benefits under default max age" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_at("fac_a", "REF-VA-45")
          authorize_referral!(referral)
          claim_service_date = Date.new(2025, 6, 15)
          stamp_alternate_resources_for_claim_service_date!(referral, claim_service_date)
          referral.alternate_resource_checks.find_by!(resource_type: "va_benefits").update!(checked_at: 45.days.ago)

          claim = build_claim(
            facility: "fac_a",
            referral_identifier: "REF-VA-45",
            patient: referral.case.patient_identifier,
            service_date: claim_service_date
          )
          claim.save!

          @verify_calls.clear
          claim.submit!

          assert_equal "submitted", claim.reload.status
          refute_includes @verify_calls.map { |c| c[1] }, "va_benefits"
        end
      end
    end

    test "submit! re-verifies va_benefits when older than configured max age override" do
      with_tenant(TENANT) do
        Corvid.configure do |c|
          c.alternate_resource_check_max_age = { "va_benefits" => 60.days }
        end

        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_at("fac_a", "REF-VA-OVERRIDE")
          authorize_referral!(referral)
          claim_service_date = Date.new(2025, 6, 15)
          stamp_alternate_resources_for_claim_service_date!(referral, claim_service_date)
          referral.alternate_resource_checks.find_by!(resource_type: "va_benefits").update!(checked_at: 61.days.ago)

          claim = build_claim(
            facility: "fac_a",
            referral_identifier: "REF-VA-OVERRIDE",
            patient: referral.case.patient_identifier,
            service_date: claim_service_date
          )
          claim.save!

          @verify_calls.clear
          claim.submit!

          assert_equal "submitted", claim.reload.status
          assert_includes @verify_calls.map { |c| c[1] }, "va_benefits"
        end
      end
    ensure
      Corvid.reset_configuration!
    end

    test "medicaid at 31 days remains stale under per-type max age defaults" do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
          referral = referral_at("fac_a", "REF-MCD-31")
          authorize_referral!(referral)
          dos = Date.new(2025, 6, 15)
          stamp_alternate_resources_for_claim_service_date!(referral, dos)
          medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
          medicaid.update!(checked_at: 31.days.ago)

          refute medicaid.current_for?(dos, as_of: Time.current)

          claim = build_claim(
            facility: "fac_a",
            referral_identifier: "REF-MCD-31",
            patient: referral.case.patient_identifier,
            service_date: dos
          )
          claim.save!

          @verify_calls.clear
          claim.submit!

          assert_equal "submitted", claim.reload.status
          assert_includes @verify_calls.map { |c| c[1] }, "medicaid"
        end
      end
    end

    test "submit! without linked referral keeps existing behaviour" do
      with_tenant(TENANT) do
        claim = build_claim(
          facility: "fac_a",
          referral_identifier: "EXTERNAL-REF-668",
          patient: "pt-external-668",
          service_date: Date.current
        )
        claim.save!

        claim.submit!
        assert_equal "submitted", claim.reload.status
      end
    end

    private

    def alternate_resource_check_snapshot(referral)
      referral.alternate_resource_checks.reload.sort_by(&:resource_type).map do |check|
        [ check.resource_type, check.status, check.checked_at&.to_i ]
      end
    end

    def create_referral_record
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        estimated_cost: 5_000
      )
    end

    def referral_in_alternate_resource_review
      referral = create_referral_record
      seed_adapter(referral)
      referral.submit!
      referral.begin_eligibility_review!
      complete_non_approval_checklist!(referral)
      referral.request_management_approval!
      referral.pending_approval_by = "pr_mgr_test"
      referral.approve_management!
      assert_equal "alternate_resource_review", referral.status
      referral
    end

    def create_all_determined_checks(referral, status_overrides = {})
      AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        check = referral.alternate_resource_checks.find_or_initialize_by(resource_type: type)
        check.status = status_overrides.fetch(type, "not_enrolled")
        check.save!
        stamp_alternate_resource_check_current!(check, date_of_service: Date.current) unless check.not_checked? || check.checking?
      end
      referral.alternate_resource_checks.reload
    end

    def seed_adapter(referral)
      Corvid.adapter.add_referral(
        referral.referral_identifier,
        patient_identifier: PATIENT,
        status: "pending",
        estimated_cost: referral.estimated_cost || 5_000,
        service_requested: "TEST"
      )
    end

    def complete_non_approval_checklist!(referral)
      checklist = referral.eligibility_checklist || referral.create_eligibility_checklist!(
        tenant_identifier: referral.tenant_identifier,
        facility_identifier: referral.facility_identifier
      )
      checklist.verify_item!(:application_complete, by: "clerk_test")
      checklist.verify_item!(:identity_verified, source: "manual")
      checklist.verify_item!(:insurance_verified, source: "manual")
      checklist.verify_item!(:residency_verified, source: "manual")
      checklist.verify_item!(:enrollment_verified, source: "manual")
      checklist.verify_item!(:clinical_necessity_documented, source: "manual")
    end

    def referral_at(facility, identifier)
      kase = Case.create!(
        patient_identifier: "pt_#{identifier}",
        facility_identifier: facility
      )
      PrcReferral.create!(
        case: kase,
        referral_identifier: identifier,
        facility_identifier: facility
      )
    end

    def build_claim(facility:, referral_identifier:, patient:, service_date:)
      ClaimSubmission.new(
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

    def committee_approved_review_with_stale_medicaid
      referral = referral_in_alternate_resource_review
      create_all_determined_checks(referral)
      assert referral.verify_alternate_resources!
      referral.update!(medical_priority: 3, estimated_cost: 5_000)
      assert referral.complete_priority_assignment!
      assert_equal "committee_review", referral.status
      exhaust_alternate_resources!(referral, date_of_service: Date.current, as_of: Time.current)
      referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)
      review = CommitteeReview.create!(
        prc_referral: referral,
        committee_date: Date.current,
        decision: "approved",
        approved_amount: 5_000,
        facility_identifier: FACILITY,
        reviewer_identifier: "rv_stale_gate"
      )
      [ referral, review ]
    end

    def sync_recording_adapter
      verify_calls = []
      Class.new do
        include EchoingVerifyEligibilityHelper
        define_method(:initialize) { @verify_calls = verify_calls }
        define_method(:verify_calls) { @verify_calls }
        define_method(:update_referral) { |_id, _params| true }
        define_method(:fetch_text) { |_token| "" }
        define_method(:verify_eligibility) do |patient_identifier, resource_type, date_of_service: nil|
          @verify_calls << [ patient_identifier, resource_type, date_of_service ]
          echo_verify_eligibility_date({ eligible: false }, date_of_service)
        end
      end.new
    end

    def authorize_referral!(referral)
      referral.submit!
      referral.begin_eligibility_review!
      checklist = referral.eligibility_checklist
      EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
        fields = EligibilityChecklist::ITEM_FIELDS.fetch(item)
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
      referral.authorize! if referral.may_authorize?
      referral.reload
    end
  end
end
