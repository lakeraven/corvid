# frozen_string_literal: true

require "test_helper"

module Corvid
  class MedicaidReferralWorkflowTest < ActiveSupport::TestCase
    TENANT = "tnt_test"
    FACILITY = "fac_test"
    PATIENT = "TEST,PATIENT 001"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    test "authorize_with_medicaid_primary! coordinates enrolled medicaid and authorizes through AASM" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        assert medicaid.enrolled?, "precondition"
        refute referral.authorized?

        workflow = Corvid::MedicaidReferralWorkflow.new
        workflow.authorize_with_medicaid_primary!(referral)

        referral.reload
        medicaid.reload
        assert medicaid.coordinated?, "Medicaid primary payer is recorded by coordinating the check"
        assert_equal "authorized", referral.status
        assert referral.alternate_resources_exhausted?
        assert_empty referral.authorization_blockers
      end
    end

    test "authorize_with_medicaid_primary! refuses when medicaid is not enrolled and leaves checks unchanged" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determermined_checks(referral, "medicaid" => "not_enrolled")
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        before = medicaid.attributes.slice("status", "checked_at", "policy_token")

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/medicaid/, error.message)
        assert_match(/medicaid: not enrolled/, error.message)
        assert_equal before, medicaid.reload.attributes.slice("status", "checked_at", "policy_token")
        refute referral.authorized?
      end
    end

    test "authorize_with_medicaid_primary! refuses when medicaid check is missing" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determermined_checks(referral)
        referral.alternate_resource_checks.find_by(resource_type: "medicaid")&.destroy!

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_includes error.message, "medicaid: not checked"
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! refuses when medicaid is still verifying" do
      with_tenant(TENANT) do
        referral = referral_in_alternate_resource_review
        create_all_determermined_checks(referral, "medicaid" => "checking")

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_includes error.message, "medicaid: checking"
        assert_equal "checking", referral.alternate_resource_checks.find_by!(resource_type: "medicaid").status
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! rolls back medicaid coordination when authorization guard still blocks" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicare_a = referral.alternate_resource_checks.find_by!(resource_type: "medicare_a")
        medicare_a.update!(status: "enrolled", checked_at: Time.current)
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        assert medicaid.enrolled?

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_includes error.message, "medicare_a: enrolled (coordination of benefits not complete)"
        medicaid.reload
        assert medicaid.enrolled?, "coordination must not persist when authorization is refused"
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! rolls back when referral cannot authorize from its workflow state" do
      with_tenant(TENANT) do
        referral = create_referral_record
        seed_adapter(referral)
        create_all_determermined_checks(referral, "medicaid" => "enrolled")
        assert_equal "draft", referral.status

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/referral: draft/, error.message)
        assert referral.alternate_resource_checks.find_by!(resource_type: "medicaid").enrolled?
        refute referral.reload.authorized?
      end
    end

    test "constructor accepts an injected adapter per ADR 0005" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        fake = Corvid.adapter
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: fake)

        workflow.authorize_with_medicaid_primary!(referral)

        assert_equal "authorized", referral.reload.status
      end
    end

    test "authorize_with_medicaid_primary! re-verifies stale medicaid through the injected adapter before coordinating" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update_columns(
          checked_at: 60.days.ago,
          coverage_start: Date.new(2020, 1, 1),
          coverage_end: Date.new(2020, 12, 31)
        )
        refute medicaid.reload.current_for?(Date.current)

        adapter = medicaid_injected_adapter
        seed_fresh_medicaid_coverage!(adapter, PATIENT)
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: adapter)

        workflow.authorize_with_medicaid_primary!(referral)

        assert_equal [ [ PATIENT, "medicaid" ] ], adapter.verify_eligibility_calls
        medicaid.reload
        assert medicaid.coordinated?
        assert_equal "authorized", referral.reload.status
      end
    end

    test "authorize_with_medicaid_primary! refuses enrolled medicaid that is not current_for today" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update_columns(
          checked_at: 60.days.ago,
          coverage_start: Date.new(2020, 1, 1),
          coverage_end: Date.new(2020, 12, 31)
        )
        refute medicaid.reload.current_for?(Date.current)
        before = medicaid.attributes.slice("status", "checked_at", "policy_token")

        adapter = medicaid_injected_adapter
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: adapter)
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/medicaid: not current/, error.message)
        assert_equal before, medicaid.reload.attributes.slice("status", "checked_at", "policy_token")
        refute medicaid.coordinated?
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! refuses when injected adapter answers medicaid not enrolled" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update_columns(checked_at: 60.days.ago)
        refute medicaid.reload.current_for?(Date.current)

        adapter = medicaid_injected_adapter
        adapter.add_coverage(PATIENT, resource_type: "medicaid", eligible: false)
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: adapter)
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/medicaid/, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! re-verifies enrolled medicaid with no coverage period when current_for? is false" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update_columns(coverage_start: nil, coverage_end: nil, checked_at: Time.current)
        medicaid.reload
        refute medicaid.current_for?(Date.current)
        before = medicaid.attributes.slice("status", "checked_at", "policy_token")

        adapter = medicaid_injected_adapter
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: adapter)
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_equal [ [ PATIENT, "medicaid" ] ], adapter.verify_eligibility_calls
        assert_match(/medicaid: not current/, error.message)
        assert_equal before, medicaid.reload.attributes.slice("status", "checked_at", "policy_token")
        refute medicaid.coordinated?
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! re-verifies enrolled medicaid with only coverage_end when current_for? is false" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update_columns(
          coverage_start: nil,
          coverage_end: Date.current.end_of_year,
          checked_at: Time.current
        )
        medicaid.reload
        refute medicaid.current_for?(Date.current)

        adapter = medicaid_injected_adapter
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: adapter)
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_equal [ [ PATIENT, "medicaid" ] ], adapter.verify_eligibility_calls
        assert_match(/medicaid: not current/, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! re-verifies enrolled medicaid with future checked_at when current_for? is false" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update_columns(
          checked_at: 1.hour.from_now,
          coverage_start: Date.current.beginning_of_year,
          coverage_end: Date.current.end_of_year
        )
        medicaid.reload
        refute medicaid.current_for?(Date.current)

        adapter = medicaid_injected_adapter
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: adapter)
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_equal [ [ PATIENT, "medicaid" ] ], adapter.verify_eligibility_calls
        assert_match(/medicaid: not current/, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! refuses seeded medicaid with nil checked_at until adapter confirms coverage" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update_columns(checked_at: nil)
        refute medicaid.reload.current_for?(Date.current)

        adapter = medicaid_injected_adapter
        workflow = Corvid::MedicaidReferralWorkflow.new(adapter: adapter)
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/medicaid: not current/, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! refuses when EHR priority requires committee with nil local medical_priority" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(medical_priority: nil, flagged_for_review: false)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: referral.estimated_cost,
          medical_priority_level: 4,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        status_before = referral.status

        assert_equal 4, referral.service_request.medical_priority_level
        assert referral.requires_committee?,
          "effective priority 4 must require committee before medicaid primary authorization"

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
        assert_equal status_before, referral.status
        assert_equal 0, referral.committee_reviews.count
        ehr = Corvid.adapter.find_referral(referral.referral_identifier)
        refute_equal "A", ehr.chs_approval_status
      end
    end

    test "authorize_with_medicaid_primary! refuses unknown priority through committee review not authorization" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(medical_priority: nil, flagged_for_review: false)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: referral.estimated_cost,
          medical_priority_level: nil,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")

        assert referral.requires_committee?,
          "unknown priority must fail closed into committee review before medicaid authorization"

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
        assert_equal 0, referral.committee_reviews.count
      end
    end

    test "authorize_with_medicaid_primary! refuses flagged referrals that require committee review" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update!(flagged_for_review: true)
        assert referral.requires_committee?
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        status_before = referral.status

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
        assert_equal status_before, referral.status
        assert_equal 0, referral.committee_reviews.count
      end
    end

    test "authorize_with_medicaid_primary! refuses referrals at the committee cost threshold" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update!(estimated_cost: 50_000, flagged_for_review: false, medical_priority: 2)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: 50_000,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        assert referral.requires_committee?
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! refuses referrals already in committee_review" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(flagged_for_review: true)
        referral.reload
        referral.alternate_resource_checks.find_by!(resource_type: "medicaid").mark_coordinated!
        referral.alternate_resource_checks.reset
        assert referral.verify_alternate_resources!
        assert referral.complete_priority_assignment!
        assert_equal "committee_review", referral.reload.status

        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        assert_equal "committee_review", referral.reload.status
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! syncs authorized chs_approval_status to the EHR" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization

        Corvid::MedicaidReferralWorkflow.new.authorize_with_medicaid_primary!(referral)

        assert_equal "authorized", referral.reload.status
        ehr = Corvid.adapter.find_referral(referral.referral_identifier)
        assert_equal "A", ehr.chs_approval_status
      end
    end

    test "complete_priority_assignment! landing on authorized syncs chs_approval_status A to the EHR" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.alternate_resource_checks.find_by!(resource_type: "medicaid").mark_coordinated!
        assert referral.verify_alternate_resources!
        assert_equal "priority_assignment", referral.reload.status

        assert referral.complete_priority_assignment!

        assert_equal "authorized", referral.reload.status
        ehr = Corvid.adapter.find_referral(referral.referral_identifier)
        assert_equal "A", ehr.chs_approval_status
      end
    end

    test "complete_priority_assignment! landing on committee_review does not sync chs_approval_status A" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(flagged_for_review: true)
        referral.reload
        assert referral.requires_committee?
        referral.alternate_resource_checks.find_by!(resource_type: "medicaid").mark_coordinated!
        assert referral.verify_alternate_resources!

        assert referral.complete_priority_assignment!

        assert_equal "committee_review", referral.reload.status
        ehr = Corvid.adapter.find_referral(referral.referral_identifier)
        refute_equal "A", ehr.chs_approval_status
      end
    end

    test "authorize_with_medicaid_primary! refuses when estimated cost is unknown locally and from the adapter" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(estimated_cost_cents: nil, medical_priority: 1, flagged_for_review: false)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: nil,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload
        refute referral.requires_committee?
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        status_before = referral.status

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/unknown cost/i, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
        assert_equal status_before, referral.status
        assert_equal 0, referral.committee_reviews.count
      end
    end

    test "authorize_with_medicaid_primary! refuses when medical priority is unknown locally and in the adapter" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(medical_priority: nil, flagged_for_review: false)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: referral.estimated_cost,
          medical_priority_level: nil,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        status_before = referral.status

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
        assert_equal status_before, referral.reload.status
        assert_equal 0, referral.committee_reviews.count
      end
    end

    test "authorize_with_medicaid_primary! leaves caller referral aligned with database after committee review refusal" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.alternate_resource_checks.find_by!(resource_type: "medicaid").mark_coordinated!
        referral.alternate_resource_checks.reset
        referral.update_columns(flagged_for_review: true)
        referral.reload
        db_status = referral.status

        workflow = Corvid::MedicaidReferralWorkflow.new
        assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_equal referral.class.find(referral.id).status, referral.status
        refute referral.authorize!
        assert_equal db_status, referral.class.find(referral.id).status
        refute referral.authorized?
        assert_equal 0, referral.committee_reviews.count
        ehr = Corvid.adapter.find_referral(referral.referral_identifier)
        refute_equal "A", ehr.chs_approval_status
      end
    end

    test "authorize_with_medicaid_primary! leaves caller referral aligned with database after unknown cost refusal" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(estimated_cost_cents: nil, medical_priority: 2, flagged_for_review: false)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: nil,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload
        refute referral.requires_committee?
        db_status = referral.status

        workflow = Corvid::MedicaidReferralWorkflow.new
        assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_equal referral.class.find(referral.id).status, referral.status
        refute referral.authorize!
        assert_equal db_status, referral.class.find(referral.id).status
        refute referral.authorized?
        assert_equal 0, referral.committee_reviews.count
        ehr = Corvid.adapter.find_referral(referral.referral_identifier)
        refute_equal "A", ehr.chs_approval_status
      end
    end

    test "authorize_with_medicaid_primary! refuses when EHR estimated_cost is formatted $60,000" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(estimated_cost_cents: nil, medical_priority: 2, flagged_for_review: false)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: "$60,000",
          medical_priority_level: 2,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")

        assert referral.requires_committee?,
          "formatted EHR cost must require committee before medicaid primary authorization"

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
      end
    end

    {
      BigDecimal("NaN") => "BigDecimal NaN",
      -75_000 => "negative integer -75_000",
      Money.from_amount(40_000, "KWD") => "Money KWD 40,000"
    }.each do |ehr_cost, label|
      test "authorize_with_medicaid_primary! refuses committee review for unknown EHR cost #{label}" do
        with_tenant(TENANT) do
          referral = referral_ready_for_medicaid_primary_authorization
          referral.update_columns(estimated_cost_cents: nil, medical_priority: nil, flagged_for_review: false)
          Corvid.adapter.add_referral(
            referral.referral_identifier,
            patient_identifier: PATIENT,
            status: "pending",
            estimated_cost: ehr_cost,
            medical_priority_level: 2,
            emergent: false,
            urgent: false,
            chs_approval_status: "P",
            service_requested: "TEST"
          )
          referral.reload
          medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
          status_before = referral.status

          assert referral.requires_committee?,
            "unknown EHR cost #{label} must require committee before medicaid primary authorization"

          workflow = Corvid::MedicaidReferralWorkflow.new
          error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
            workflow.authorize_with_medicaid_primary!(referral)
          end

          assert_match(/committee review/i, error.message)
          refute medicaid.reload.coordinated?
          refute referral.reload.authorized?
          assert_equal status_before, referral.status
          assert_equal 0, referral.committee_reviews.count
          ehr = Corvid.adapter.find_referral(referral.referral_identifier)
          refute_equal "A", ehr.chs_approval_status
        end
      end
    end

    test "authorize_with_medicaid_primary! refuses committee review when EHR priority is string digits above threshold" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.update_columns(medical_priority: nil, flagged_for_review: false)
        Corvid.adapter.add_referral(
          referral.referral_identifier,
          patient_identifier: PATIENT,
          status: "pending",
          estimated_cost: referral.estimated_cost,
          medical_priority_level: "4",
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        referral.reload
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")

        assert_nothing_raised { assert referral.requires_committee? }

        workflow = Corvid::MedicaidReferralWorkflow.new
        error = assert_raises(Corvid::MedicaidReferralWorkflow::Refused) do
          workflow.authorize_with_medicaid_primary!(referral)
        end

        assert_match(/committee review/i, error.message)
        refute medicaid.reload.coordinated?
        refute referral.reload.authorized?
      end
    end

    test "authorize_with_medicaid_primary! succeeds when MedicaidEligibilityGroupService#record! aborts the database inside an outer transaction" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        medicaid.update_columns(
          checked_at: 60.days.ago,
          coverage_start: Date.new(2020, 1, 1),
          coverage_end: Date.new(2020, 12, 31)
        )
        refute medicaid.reload.current_for?(Date.current)

        adapter = medicaid_injected_adapter
        seed_fresh_medicaid_coverage!(adapter, PATIENT)
        failing_service = StatementInvalidMedicaidEligibilityGroupService.new

        log_io = capture_workflow_warn_log do
          Corvid::MedicaidEligibilityGroupService.stub(:new, ->(**) { failing_service }) do
            workflow = Corvid::MedicaidReferralWorkflow.new(adapter: adapter)
            ActiveRecord::Base.transaction do
              workflow.authorize_with_medicaid_primary!(referral)
              referral.update_columns(updated_at: Time.current)
            end
          end
        end

        assert_equal "authorized", referral.reload.status
        assert medicaid.reload.coordinated?
        assert_includes log_io.string, Corvid::AlternateResourceCheck::VERIFY_MEDICAID_ELIGIBILITY_GROUP_WARNING
        refute_includes log_io.string, PATIENT
      end
    end

    test "authorize_with_medicaid_primary! leaves medicaid enrolled when Refused is rescued in an outer transaction" do
      with_tenant(TENANT) do
        referral = referral_ready_for_medicaid_primary_authorization
        referral.alternate_resource_checks.find_by!(resource_type: "medicare_a").update_columns(status: "enrolled")
        medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
        assert medicaid.enrolled?

        workflow = Corvid::MedicaidReferralWorkflow.new
        ActiveRecord::Base.transaction do
          begin
            workflow.authorize_with_medicaid_primary!(referral)
          rescue Corvid::MedicaidReferralWorkflow::Refused
          end
        end

        medicaid.reload
        assert medicaid.enrolled?
        refute medicaid.coordinated?
        refute referral.reload.authorized?
      end
    end

    private

    class StatementInvalidMedicaidEligibilityGroupService
      def record!(*)
        Corvid::AlternateResourceCheck.connection.execute(
          "SELECT 1 FROM corvid_nonexistent_eligibility_group_stub"
        )
      end
    end

    def capture_workflow_warn_log
      log_io = StringIO.new
      original_logger = Rails.logger
      logger = ActiveSupport::Logger.new(log_io)
      logger.level = ::Logger::WARN
      Rails.logger = logger
      yield
      log_io
    ensure
      Rails.logger = original_logger if original_logger
    end

    class MedicaidInjectedAdapter < Corvid::Adapters::MockAdapter
      attr_reader :verify_eligibility_calls

      def initialize
        super()
        @verify_eligibility_calls = []
      end

      def verify_eligibility(patient_identifier, resource_type)
        @verify_eligibility_calls << [ patient_identifier, resource_type ]
        super(patient_identifier, resource_type)
      end
    end

    def medicaid_injected_adapter
      MedicaidInjectedAdapter.new
    end

    def seed_fresh_medicaid_coverage!(adapter, patient_identifier)
      adapter.add_coverage(
        patient_identifier,
        resource_type: "medicaid",
        eligible: true,
        coverage_start: Date.current.beginning_of_year,
        coverage_end: Date.current.end_of_year + 1.year
      )
    end

    def create_referral_record
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        medical_priority: 2,
        flagged_for_review: false,
        estimated_cost: 5_000
      )
    end

    def seed_adapter(referral)
      Corvid.adapter.add_referral(
        referral.referral_identifier,
        patient_identifier: PATIENT,
        status: "pending",
        estimated_cost: referral.estimated_cost,
        emergent: false,
        urgent: false,
        chs_approval_status: "P",
        service_requested: "TEST"
      )
    end

    def complete_non_approval_checklist!(referral)
      checklist = referral.eligibility_checklist || referral.create_eligibility_checklist!(
        tenant_identifier: referral.tenant_identifier,
        facility_identifier: referral.facility_identifier
      )

      checklist.verify_item!(:application_complete, by: "clerk_1")
      checklist.verify_item!(:identity_verified, source: "manual")
      checklist.verify_item!(:insurance_verified, source: "manual")
      checklist.verify_item!(:residency_verified, source: "manual")
      checklist.verify_item!(:enrollment_verified, source: "manual")
      checklist.verify_item!(:clinical_necessity_documented, source: "manual")
    end

    def referral_in_alternate_resource_review
      referral = create_referral_record
      seed_adapter(referral)
      referral.submit!
      referral.begin_eligibility_review!
      complete_non_approval_checklist!(referral)
      referral.request_management_approval!
      referral.pending_approval_by = "pr_mgr"
      referral.approve_management!
      assert_equal "alternate_resource_review", referral.status
      referral
    end

    def referral_ready_for_medicaid_primary_authorization
      referral = referral_in_alternate_resource_review
      create_all_determermined_checks(referral, "medicaid" => "enrolled")
      medicaid = referral.alternate_resource_checks.find_by!(resource_type: "medicaid")
      ensure_enrolled_medicaid_current_coverage!(medicaid)
      referral
    end

    def create_all_determermined_checks(referral, status_overrides = {})
      AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        check = referral.alternate_resource_checks.find_or_initialize_by(resource_type: type)
        check.status = status_overrides.fetch(type, "not_enrolled")
        check.checked_at = Time.current if check.status != "not_checked"
        if type == "medicaid" && check.status == "enrolled"
          check.coverage_start = Date.current.beginning_of_year
          check.coverage_end = Date.current.end_of_year + 1.year
        end
        check.save!
      end
      referral.alternate_resource_checks.reload
    end

    def ensure_enrolled_medicaid_current_coverage!(medicaid)
      medicaid.update!(
        checked_at: Time.current,
        coverage_start: Date.current.beginning_of_year,
        coverage_end: Date.current.end_of_year + 1.year
      )
      assert medicaid.current_for?(Date.current), "happy-path enrolled medicaid must be current_for? today"
    end
  end
end
