# frozen_string_literal: true

require "test_helper"

# Patient-scoped serialization of Medicaid writes during claim submission (issue #639).
class Corvid::ClaimSubmissionMedicaidHoldConcurrencyTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  TENANT = "tnt_test"
  PATIENT = "TEST,PATIENT 001"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup do
    travel_to RETRO_SCENARIO_TIME
    @records = { claim_ids: [], referral_ids: [], case_ids: [], medicaid_ids: [] }
  end

  teardown do
    travel_back
    delete_created_records!
    Corvid::TenantContext.reset!
  end

  test "verify! and record_staff_entry! on same medicaid check complete without deadlock" do
    check = nil
    with_tenant(TENANT) do
      referral = referral_at("fac_test", "REF-DEADLOCK-#{SecureRandom.hex(3)}")
      @records[:referral_ids] << referral.id
      @records[:case_ids] << referral.case_id
      check = referral.alternate_resource_checks.find_by(resource_type: "medicaid") ||
        Corvid::AlternateResourceCheck.create!(
          prc_referral: referral,
          resource_type: "medicaid",
          status: "not_checked"
        )
      @records[:medicaid_ids] << check.id
    end

    adapter_started = Queue.new
    release_adapter = Queue.new
    Corvid.adapter.define_singleton_method(:verify_eligibility) do |*_args|
      adapter_started.push(true)
      release_adapter.pop
      { eligible: false }
    end

    outcomes = Queue.new

    verify_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Corvid::TenantContext.with_tenant(TENANT) do
          Corvid::AlternateResourceCheck.unscoped.find(check.id).verify!
          outcomes.push([ :verify, :ok ])
        rescue StandardError => error
          outcomes.push([ :verify, error.class.name ])
        end
      end
    end

    adapter_started.pop

    staff_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Corvid::TenantContext.with_tenant(TENANT) do
          Corvid::MedicaidEligibilityGroupService.new(adapter: Corvid.adapter).record_staff_entry!(
            Corvid::AlternateResourceCheck.unscoped.find(check.id),
            eligibility_group: "waiver_adult"
          )
          outcomes.push([ :staff_entry, :ok ])
        rescue StandardError => error
          outcomes.push([ :staff_entry, error.class.name ])
        end
      end
    end

    overlap_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < overlap_deadline
      Thread.pass
    end
    release_adapter.push(true)

    assert verify_thread.join(10), "verify! thread should finish"
    assert staff_thread.join(10), "record_staff_entry! thread should finish"

    results = []
    results << outcomes.pop until outcomes.empty?

    refute results.any? { |_, result| result.to_s.include?("Deadlock") }, results.inspect
    assert_equal [ [ :staff_entry, :ok ], [ :verify, :ok ] ], results.sort_by(&:first)
  ensure
    verify_thread&.kill if verify_thread&.alive?
    staff_thread&.kill if staff_thread&.alive?
  end

  test "medicaid check update waits until submit! adapter call finishes for same patient" do
    claim = nil
    medicaid = nil
    with_tenant(TENANT) do
      claim, medicaid = held_claim_with_override!
      @records[:claim_ids] << claim.id
      @records[:referral_ids] << claim.prc_referral_id if claim.prc_referral_id
      @records[:medicaid_ids] << medicaid.id
      @records[:case_ids] << medicaid.prc_referral.case_id
    end

    adapter_started = Queue.new
    writer_go = Queue.new
    release_adapter = Queue.new

    Corvid.adapter.define_singleton_method(:submit_claim) do |_data|
      adapter_started.push(true)
      release_adapter.pop
      { claim_identifier: "CLM-LOCK-SPEC", status: "accepted" }
    end

    writer_finished = Queue.new
    writer_error = nil

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_go.pop
        Corvid::TenantContext.with_tenant(TENANT) do
          check = Corvid::AlternateResourceCheck.unscoped.find(medicaid.id)
          begin
            check.update!(application_date: Date.new(2027, 3, 16))
            writer_finished.push(:done)
          rescue StandardError => error
            writer_error = error
            writer_finished.push(:error)
          end
        end
      end
    end

    submit_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Corvid::TenantContext.with_tenant(TENANT) do
          Corvid::ClaimSubmission.unscoped.find(claim.id).submit!
        end
      end
    end

    adapter_started.pop

    writer_go.push(true)

    writer_wait_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    while writer_finished.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < writer_wait_deadline
      Thread.pass
    end
    assert writer_finished.empty?,
      "concurrent Medicaid update must block until submission completes (writer finished too early)"

    release_adapter.push(true)
    submit_thread.join(5)
    writer.join(5)

    assert submit_thread.join(5), "submit thread should finish"
    assert_equal :done, writer_finished.pop
    assert_nil writer_error

    claim.reload
    assert_equal "submitted", claim.status
    assert_equal Date.new(2027, 3, 16), medicaid.reload.application_date
  ensure
    writer&.kill if writer&.alive?
    submit_thread&.kill if submit_thread&.alive?
  end

  private

  def held_claim_with_override!
    referral = referral_at("fac_test", "REF-CONC-#{SecureRandom.hex(3)}")
    @records[:referral_ids] << referral.id
    @records[:case_ids] << referral.case_id
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
    claim = Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier,
      referral_identifier: referral.referral_identifier,
      claim_type: "professional",
      service_date: Date.new(2027, 2, 1),
      billed_amount: 100.0,
      status: "draft"
    )
    claim.override_medicaid_hold!(
      reason_token: "rt_medicaid_hold_override",
      by_identifier: "usr_billing_spec"
    )
    [ claim, medicaid ]
  end

  def delete_created_records!
    Corvid::Determination.unscoped.where(
      determinable_type: "Corvid::ClaimSubmission",
      determinable_id: @records[:claim_ids]
    ).delete_all
    Corvid::ClaimSubmission.unscoped.where(id: @records[:claim_ids]).delete_all
    Corvid::EligibilityChecklist.unscoped.where(prc_referral_id: @records[:referral_ids]).delete_all
    Corvid::AlternateResourceCheck.unscoped.where(prc_referral_id: @records[:referral_ids]).delete_all
    Corvid::PrcReferral.unscoped.where(id: @records[:referral_ids]).delete_all
    Corvid::Case.unscoped.where(id: @records[:case_ids]).delete_all
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
end
