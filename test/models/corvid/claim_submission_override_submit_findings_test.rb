# frozen_string_literal: true

require "test_helper"

# Pins for #639 / PR #688 gate findings 1–5 (chair design). Fail on current
# single-transaction submit until two-phase commit and top-level checks land.
class Corvid::ClaimSubmissionOverrideSubmitFindingsTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  TENANT = "tnt_test"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup { travel_to RETRO_SCENARIO_TIME }

  teardown do
    travel_back
    Corvid::TenantContext.reset!
    truncate_corvid_claim_graph!
  end

  test "thread killed during adapter call leaves override spent and unknown marker set" do
    claim_id = nil
    with_tenant(TENANT) { claim_id = held_draft_with_override!.id }
    started = Queue.new
    Corvid.adapter.define_singleton_method(:submit_claim) do |_data|
      started.push(true)
      sleep 30
    end
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Corvid::TenantContext.with_tenant(TENANT) do
          Corvid::ClaimSubmission.find(claim_id).submit!
        end
      end
    end
    started.pop
    thread.kill
    thread.join(10)

    row = fresh_claim_row(claim_id)
    assert_override_spent_row!(row)
    assert submission_outcome_unknown_row?(row),
      "phase A must commit the in-flight marker before the adapter runs"
  end

  test "SIGKILL during adapter call leaves override spent and unknown marker set" do
    unless Process.respond_to?(:fork)
      skip "fork is not available on this platform"
    end

    claim_id = nil
    with_tenant(TENANT) { claim_id = held_draft_with_override!.id }
    ActiveRecord::Base.connection_pool.disconnect!
    child = fork do
      ActiveRecord::Base.establish_connection
      Corvid.adapter.define_singleton_method(:submit_claim) do |_data|
        Process.kill(:KILL, Process.pid)
      end
      Corvid::TenantContext.with_tenant(TENANT) do
        Corvid::ClaimSubmission.find(claim_id).submit!
      end
    end
    Process.wait(child)
    ActiveRecord::Base.establish_connection

    row = fresh_claim_row(claim_id)
    assert_override_spent_row!(row)
    assert submission_outcome_unknown_row?(row)
  end

  test "adapter aborting the Postgres transaction leaves override spent and marker set" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      sends = []
      Corvid.adapter.define_singleton_method(:submit_claim) do |data|
        sends << data
        ActiveRecord::Base.connection.execute("SELECT 1/0")
        { claim_identifier: "CLM-ABORT-#{sends.size}", status: "accepted" }
      end

      assert_raises(Exception) { claim.submit! }

      row = fresh_claim_row(claim.id)
      assert_equal 1, sends.size
      assert_override_spent_row!(row)
      assert submission_outcome_unknown_row?(row)

      submit_calls = stub_submit_claim!
      assert_raises(outcome_unknown_error_class) { Corvid::ClaimSubmission.find(claim.id).submit! }
      assert_empty submit_calls
    end
  end

  test "duplicate claim_identifier on accepted result leaves override spent and marker set" do
    with_tenant(TENANT) do
      duplicate_identifier = "CLM-DUP-#{SecureRandom.hex(4)}"
      seed_submitted_claim!(claim_identifier: duplicate_identifier)

      claim = held_draft_with_override!
      sends = []
      Corvid.adapter.define_singleton_method(:submit_claim) do |data|
        sends << data
        { claim_identifier: duplicate_identifier, status: "accepted" }
      end

      assert_raises(Exception) { claim.submit! }

      row = fresh_claim_row(claim.id)
      assert_equal 1, sends.size
      assert_override_spent_row!(row)
      assert submission_outcome_unknown_row?(row)

      determinations_before = determination_count_for(claim)
      assert_raises(outcome_unknown_error_class) do
        Corvid::ClaimSubmission.find(claim.id).override_medicaid_hold!(
          reason_token: "rt_should_not_record",
          by_identifier: "usr_blocked"
        )
      end
      assert_equal determinations_before, determination_count_for(claim)
    end
  end

  test "submit! with override inside non-joinable caller transaction raises before adapter" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      override_token = claim.medicaid_hold_override_reason_token
      submit_calls = stub_submit_claim!

      error = assert_raises(top_level_error_class) do
        Corvid::ClaimSubmission.transaction(joinable: false) do
          claim.submit!
        end
      end

      assert_instance_of top_level_error_class, error
      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_equal override_token, row.medicaid_hold_override_reason_token
      assert row.medicaid_hold_overridden_at.present?
      assert_equal "draft", row.status
    end
  end

  test "concurrent override_medicaid_hold! during in-flight submit raises and records nothing" do
    claim_id = nil
    with_tenant(TENANT) { claim_id = held_draft_with_override!.id }

    started = Queue.new
    release = Queue.new
    Corvid.adapter.define_singleton_method(:submit_claim) do |_data|
      started.push(true)
      release.pop
      { claim_identifier: "CLM-CONCURRENT", status: "accepted" }
    end

    results = Queue.new
    submit_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Corvid::TenantContext.with_tenant(TENANT) do
          Corvid::ClaimSubmission.find(claim_id).submit!
        rescue Exception => error
          results.push([ :submit, error.class.name ])
        end
      end
    end

    started.pop
    row_mid_send = fresh_claim_row(claim_id)
    assert submission_outcome_unknown_row?(row_mid_send),
      "marker must be visible after phase A commits, before the adapter returns"

    override_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Corvid::TenantContext.with_tenant(TENANT) do
          Corvid::ClaimSubmission.find(claim_id).override_medicaid_hold!(
            reason_token: "rt_concurrent",
            by_identifier: "usr_concurrent"
          )
          results.push([ :override, :ok ])
        rescue Exception => error
          results.push([ :override, error.class.name ])
        end
      end
    end

    release.push(true)
    submit_thread.join(10)
    override_thread.join(10)

    out = []
    out << results.pop until results.empty?
    assert_equal "SubmissionOutcomeUnknown", out.find { |kind, _| kind == :override }&.last

    row = fresh_claim_row(claim_id)
    assert_nil row.medicaid_hold_override_reason_token
    assert submission_outcome_unknown_row?(row)
    assert_equal 1, Corvid::Determination.where(
      determinable_type: "Corvid::ClaimSubmission",
      determinable_id: claim_id,
      reasons_token: "rt_concurrent"
    ).count
  ensure
    submit_thread&.kill if submit_thread&.alive?
    override_thread&.kill if override_thread&.alive?
  end

  private

  def truncate_corvid_claim_graph!
    conn = ActiveRecord::Base.connection
    %w[
      corvid_determinations corvid_claim_submissions corvid_eligibility_checklists
      corvid_alternate_resource_checks corvid_prc_referrals corvid_cases
    ].each do |table|
      conn.execute("TRUNCATE #{table} CASCADE")
    end
  end

  def fresh_claim_row(claim_id)
    Corvid::ClaimSubmission.uncached do
      Corvid::ClaimSubmission.unscoped.find(claim_id)
    end
  end

  def submission_outcome_unknown_row?(row)
    row.submission_outcome_unknown_at.present?
  end

  def assert_override_spent_row!(row)
    assert_nil row.medicaid_hold_override_reason_token
    assert_nil row.medicaid_hold_override_by_identifier
    assert_nil row.medicaid_hold_overridden_at
  end

  def outcome_unknown_error_class
    Corvid::ClaimSubmission::SubmissionOutcomeUnknown
  end

  def top_level_error_class
    Corvid::ClaimSubmission::OverrideRequiresTopLevelSubmit
  end

  def held_draft_with_override!
    claim = held_draft_claim!
    claim.override_medicaid_hold!(
      reason_token: "rt_medicaid_hold_override",
      by_identifier: "usr_billing_spec"
    )
    claim.reload
  end

  def held_draft_claim!
    referral = referral_at("fac_test", "REF-FIND-#{SecureRandom.hex(3)}")
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
    build_claim_for(referral).tap(&:save!)
  end

  def seed_submitted_claim!(claim_identifier:)
    referral = referral_at("fac_test", "REF-DUP-SEED-#{SecureRandom.hex(3)}", patient: "DUP,SEED #{SecureRandom.hex(2)}")
    authorize!(referral)
    referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
    build_claim_for(referral, service_date: Date.new(2027, 2, 15)).tap do |claim|
      claim.save!
      claim.update_columns(
        claim_identifier: claim_identifier,
        status: "submitted",
        submitted_at: Time.current
      )
    end
  end

  def build_claim_for(referral, service_date: Date.new(2027, 2, 1))
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

  def referral_at(facility, identifier, patient: "TEST,PATIENT FIND-#{SecureRandom.hex(2)}")
    kase = Corvid::Case.create!(patient_identifier: patient, facility_identifier: facility)
    Corvid::PrcReferral.create!(case: kase, referral_identifier: identifier, facility_identifier: facility)
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
      { claim_identifier: "CLM-SPEC-#{calls.size}", status: "accepted" }
    end
    calls
  end

  def determination_count_for(claim)
    Corvid::Determination.where(
      determinable_type: claim.class.name,
      determinable_id: claim.id
    ).count
  end
end
