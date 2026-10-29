# frozen_string_literal: true

require "test_helper"

# Failing specs for phase-B re-verification (#639 / PR #688). Pass once
# InFlightSubmissionChanged, concurrent override restart, and marker ordering land.
class Corvid::ClaimSubmissionPhaseBRecheckTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  TENANT = "tnt_test"
  RETRO_SCENARIO_TIME = Time.zone.local(2027, 6, 1, 12, 0, 0)

  setup { travel_to RETRO_SCENARIO_TIME }

  teardown do
    travel_back
    restore_submit_in_flight_claim!
    restore_submit_without_override!
    Corvid::TenantContext.reset!
    truncate_corvid_claim_graph!
  end

  # --- A: phase B re-checks before clearinghouse --------------------------------

  test "phase B aborts with InFlightSubmissionChanged when confirm_submission_not_sent! runs in gap and clears marker for resubmit hold" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      phase_a_marker = nil
      submit_calls = stub_submit_claim!
      hook_phase_b_gap!(claim.id) do
        peer = Corvid::ClaimSubmission.find(claim.id)
        phase_a_marker = peer.submission_outcome_unknown_at
        peer.confirm_submission_not_sent!(by_identifier: "usr_reconcile_gap")
      end

      error = assert_raises_in_flight_submission_changed! { claim.submit! }

      assert_in_flight_changed_message!(error)
      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      refute submission_outcome_unknown_row?(row)
      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) do
        Corvid::ClaimSubmission.find(claim.id).submit!
      end
      refute_nil phase_a_marker
    end
  end

  test "phase B aborts with InFlightSubmissionChanged when mark_submitted! reconciles send in gap" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_submit_claim!
      reconciled_id = "CLM-GAP-MARK-#{SecureRandom.hex(3)}"
      hook_phase_b_gap!(claim.id) do
        Corvid::ClaimSubmission.find(claim.id).mark_submitted!(claim_identifier: reconciled_id)
      end

      assert_raises_in_flight_submission_changed! { claim.submit! }

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      assert_equal "submitted", row.status
      assert_equal reconciled_id, row.claim_identifier
      refute submission_outcome_unknown_row?(row)
    end
  end

  test "phase B aborts with InFlightSubmissionChanged when claim is no longer unsent in gap" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      status_at_phase_a = claim.status
      submit_calls = stub_submit_claim!
      hook_phase_b_gap!(claim.id) do
        peer = Corvid::ClaimSubmission.find(claim.id)
        peer.update_columns(status: "submitted", claim_identifier: "CLM-GAP-UNSENT", submitted_at: Time.current)
      end

      assert_raises_in_flight_submission_changed! { claim.submit! }

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      assert_equal "submitted", row.status
      assert_equal "CLM-GAP-UNSENT", row.claim_identifier
      refute_equal status_at_phase_a, "submitted" if status_at_phase_a != "submitted"
    end
  end

  test "phase B aborts with InFlightSubmissionChanged when hold basis changes in gap" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_submit_claim!
      hook_phase_b_gap!(claim.id) do
        Corvid::ClaimSubmission.find(claim.id).update!(service_date: Date.new(2027, 2, 15))
      end

      assert_raises_in_flight_submission_changed! { claim.submit! }

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      assert_equal Date.new(2027, 2, 15), row.service_date
      refute submission_outcome_unknown_row?(row),
        "basis change abort should clear unknown marker when still unsent"
      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) do
        Corvid::ClaimSubmission.find(claim.id).submit!
      end
    end
  end

  test "phase B aborts with InFlightSubmissionChanged when new pending Medicaid application appears in gap" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      patient_id = claim.patient_identifier
      submit_calls = stub_submit_claim!
      hook_phase_b_gap!(claim.id) do
        seed_patient_pending_medicaid_on_referral!(
          patient_id: patient_id,
          referral_id: "REF-GAP-PEND-#{SecureRandom.hex(3)}",
          application_date: Date.new(2027, 3, 20),
          application_date_source: "staff_entry",
          medicaid_state_code: "XA",
          eligibility_group: "expansion_adult"
        )
      end

      assert_raises_in_flight_submission_changed! { claim.submit! }

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      refute submission_outcome_unknown_row?(row)
      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) do
        Corvid::ClaimSubmission.find(claim.id).submit!
      end
    end
  end

  test "two-phase override submit with no gap sends once and records result" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_submit_claim!

      claim.submit!

      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_equal "submitted", row.status
      assert row.claim_identifier.present?
      assert_override_spent_row!(row)
      refute submission_outcome_unknown_row?(row)
    end
  end

  # --- B: concurrent override before no-override locks ----------------------------

  test "submit! restarts through two-phase override path when override is recorded before no-override locks" do
    with_tenant(TENANT) do
      claim = held_draft_claim!
      submit_calls = stub_submit_claim!
      two_phase_calls = []
      original_spending = Corvid::ClaimSubmission.instance_method(:submit_spending_medicaid_hold_override!)
      Corvid::ClaimSubmission.define_method(:submit_spending_medicaid_hold_override!) do
        two_phase_calls << true
        original_spending.bind_call(self)
      end
      inject_override_before_no_override_lock!(claim.id)

      claim.submit!

      assert_equal 1, two_phase_calls.size,
        "submit! must restart through submit_spending_medicaid_hold_override!, not only submit_without_override!"
      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_equal "submitted", row.status
      assert_override_spent_row!(row)
      refute submission_outcome_unknown_row?(row)
    end
  end

  test "concurrent override restart leaves override spent when adapter raises after call" do
    with_tenant(TENANT) do
      claim = held_draft_claim!
      submit_calls = []
      Corvid.adapter.define_singleton_method(:submit_claim) do |data|
        submit_calls << data
        raise StandardError, "adapter failed after accept"
      end
      inject_override_before_no_override_lock!(claim.id)

      assert_raises(StandardError) { claim.submit! }

      assert_equal 1, submit_calls.size
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      assert submission_outcome_unknown_row?(row),
        "two-phase path must commit spend and marker before adapter; single-transaction path would roll back override"
    end
  end

  test "concurrent override restart inside open caller transaction raises OverrideRequiresTopLevelSubmit" do
    with_tenant(TENANT) do
      claim = held_draft_claim!
      submit_calls = stub_submit_claim!
      inject_override_before_no_override_lock_on_peer_connection!(claim.id)

      assert_raises(Corvid::ClaimSubmission::OverrideRequiresTopLevelSubmit) do
        Corvid::ClaimSubmission.transaction(joinable: false) { claim.submit! }
      end

      assert_empty submit_calls
      row = fresh_claim_row(claim.id)
      assert row.medicaid_hold_override_reason_token.present?
      assert_equal "draft", row.status
    end
  end

  # --- C: marker must survive until adapter completes -----------------------------

  test "adapter throw after phase A leaves override spent and unknown marker set" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      Corvid.adapter.define_singleton_method(:submit_claim) do |_data|
        throw :halt_adapter, :halted
      end

      caught = catch(:halt_adapter) { claim.submit! }

      assert_equal :halted, caught,
        "adapter throw must halt send without recording acceptance (got #{caught.inspect})"
      row = fresh_claim_row(claim.id)
      assert_override_spent_row!(row)
      assert submission_outcome_unknown_row?(row),
        "phase B must not clear submission_outcome_unknown_at before the adapter returns"
    end
  end

  # --- D: lock and re-check pins --------------------------------------------------

  test "override_medicaid_hold! acquires row lock before persisting override" do
    with_tenant(TENANT) do
      claim = held_draft_claim!
      lock_calls = []
      Corvid::ClaimSubmission.class_eval do
        alias_method :lock_without_test_spy, :lock!
        define_method(:lock!) do |*args, **kwargs, &block|
          lock_calls << :lock! if is_a?(Corvid::ClaimSubmission) && id == claim.id
          lock_without_test_spy(*args, **kwargs, &block)
        end
      end
      begin
        claim.override_medicaid_hold!(
          reason_token: "rt_lock_pin",
          by_identifier: "usr_lock_pin"
        )
      ensure
        Corvid::ClaimSubmission.class_eval do
          alias_method :lock!, :lock_without_test_spy
          remove_method :lock_without_test_spy
        end
      end

      assert_includes lock_calls, :lock!, "override_medicaid_hold! must take the row lock (mutant: skip lock_submission_row!)"
    end
  end

  test "confirm_submission_not_sent! acquires row lock" do
    with_tenant(TENANT) do
      claim = claim_in_outcome_unknown_state!
      lock_calls = []
      Corvid::ClaimSubmission.class_eval do
        alias_method :lock_without_confirm_spy, :lock!
        define_method(:lock!) do |*args, **kwargs, &block|
          lock_calls << :lock! if is_a?(Corvid::ClaimSubmission) && id == claim.id
          lock_without_confirm_spy(*args, **kwargs, &block)
        end
      end
      begin
        claim.confirm_submission_not_sent!(by_identifier: "usr_confirm_lock")
      ensure
        Corvid::ClaimSubmission.class_eval do
          alias_method :lock!, :lock_without_confirm_spy
          remove_method :lock_without_confirm_spy
        end
      end

      assert_includes lock_calls, :lock!
    end
  end

  test "override_medicaid_hold! re-checks SubmissionOutcomeUnknown under row lock" do
    claim_id = nil
    with_tenant(TENANT) { claim_id = claim_in_outcome_unknown_state!.id }

    marker_set = Queue.new
    override_go = Queue.new
    Corvid::ClaimSubmission.class_eval do
      alias_method :lock_without_override_marker_race, :lock!
      define_method(:lock!) do |*args, **kwargs, &block|
        if is_a?(Corvid::ClaimSubmission) && id == claim_id && !submission_outcome_unknown?
          marker_set.push(true)
          override_go.pop
        end
        lock_without_override_marker_race(*args, **kwargs, &block)
      end
    end

    results = Queue.new
    override_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Corvid::TenantContext.with_tenant(TENANT) do
          Corvid::ClaimSubmission.find(claim_id).override_medicaid_hold!(
            reason_token: "rt_race_override",
            by_identifier: "usr_race_override"
          )
          results.push(:ok)
        rescue Exception => error
          results.push(error.class)
        end
      end
    end

    marker_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Corvid::TenantContext.with_tenant(TENANT) do
          marker_set.pop
          Corvid::ClaimSubmission.find(claim_id).update_columns(submission_outcome_unknown_at: Time.current)
          override_go.push(true)
        end
      end
    end

    override_thread.join(10)
    marker_thread.join(10)

    assert_equal Corvid::ClaimSubmission::SubmissionOutcomeUnknown, results.pop
    row = fresh_claim_row(claim_id)
    assert_nil row.medicaid_hold_override_reason_token
  ensure
    override_thread&.kill if override_thread&.alive?
    marker_thread&.kill if marker_thread&.alive?
    restore_lock_spy!
  end

  test "phase A re-checks submission outcome unknown marker under lock" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      submit_calls = stub_submit_claim!
      claim_id = claim.id
      injected = false
      original_mark = Corvid::ClaimSubmission.instance_method(:mark_in_flight_override_spend!)
      Corvid::ClaimSubmission.define_method(:mark_in_flight_override_spend!) do
        unless injected
          injected = true
          Corvid::ClaimSubmission.find(claim_id).update_columns(submission_outcome_unknown_at: Time.current)
        end
        original_mark.bind_call(self)
      end

      assert_raises(Corvid::ClaimSubmission::SubmissionOutcomeUnknown) { claim.submit! }

      assert_empty submit_calls
      row = fresh_claim_row(claim_id)
      assert row.medicaid_hold_override_reason_token.present?, "phase A must not spend override when marker appears under lock"
    end
  end

  test "phase A re-checks pending Medicaid hold under lock after override" do
    with_tenant(TENANT) do
      claim = held_draft_with_override!
      travel 1.second
      patient_id = claim.patient_identifier
      submit_calls = stub_submit_claim!
      claim_id = claim.id
      seeded = false
      test_case = self
      original_enforce = Corvid::ClaimSubmission.instance_method(:enforce_pending_medicaid_hold!)
      Corvid::ClaimSubmission.define_method(:enforce_pending_medicaid_hold!) do
        if !seeded && id == claim_id
          seeded = true
          test_case.send(
            :seed_patient_pending_medicaid_on_referral!,
            patient_id: patient_id,
            referral_id: "REF-PHASE-A-HOLD-#{SecureRandom.hex(3)}",
            application_date: Date.new(2027, 3, 15),
            application_date_source: "staff_entry",
            medicaid_state_code: "XA",
            eligibility_group: "expansion_adult"
          )
        end
        original_enforce.bind_call(self)
      end

      assert_raises(Corvid::ClaimSubmission::HeldForPendingMedicaid) { claim.submit! }

      assert_empty submit_calls
      row = fresh_claim_row(claim_id)
      assert row.medicaid_hold_override_reason_token.present?
      refute submission_outcome_unknown_row?(row)
    end
  end

  test "never-sent marker guard allows imported accepted row to record claim_identifier via plain save" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT,
        facility_identifier: "fac_import_pin",
        patient_identifier: "pt_import_pin_#{SecureRandom.hex(3)}",
        referral_identifier: "REF-IMPORT-PIN-#{SecureRandom.hex(3)}",
        claim_type: "professional",
        service_date: Date.new(2027, 2, 1),
        billed_amount: 100.0,
        status: "accepted"
      )
      identifier = "CLM-ACCEPTED-IMPORT-#{SecureRandom.hex(3)}"

      claim.update!(claim_identifier: identifier)

      claim.reload
      assert_equal "accepted", claim.status
      assert_equal identifier, claim.claim_identifier
    end
  end

  test "never-sent marker guard blocks unsent stored statuses from recording claim_identifier via plain save" do
    with_tenant(TENANT) do
      %w[denied rejected appealed].each do |status|
        claim = imported_never_sent_claim!(status: status)
        identifier = "CLM-#{status.upcase}-BLOCK-#{SecureRandom.hex(3)}"

        error = assert_raises(ActiveRecord::RecordInvalid) do
          claim.update!(claim_identifier: identifier)
        end

        assert_match(/submit! or mark_submitted!/i, error.message)
        claim.reload
        assert_equal status, claim.status
        assert_nil claim.claim_identifier
      end
    end
  end

  test "never-sent marker guard blocks draft row from recording claim_identifier via plain save" do
    with_tenant(TENANT) do
      claim = never_sent_draft_for_guard_pin!

      refute claim.update(claim_identifier: "CLM-DRAFT-BLOCK-#{SecureRandom.hex(3)}")
      assert claim.errors[:claim_identifier].present?
      assert_nil claim.reload.claim_identifier
    end
  end

  private

  @submit_in_flight_original = nil
  @submit_without_override_original = nil

  class << self
    attr_accessor :submit_in_flight_original, :submit_without_override_original
  end

  def hook_phase_b_gap!(claim_id, &block)
    install_submit_in_flight_hook!(claim_id, &block)
  end

  def install_submit_in_flight_hook!(claim_id)
    gap_done = false
    original = submit_in_flight_original_method
    Corvid::ClaimSubmission.define_method(:submit_in_flight_claim!) do |*args, **kwargs, &block|
      unless gap_done
        gap_done = true
        yield claim_id
      end
      original.bind_call(self, *args, **kwargs, &block)
    end
  end

  def submit_in_flight_original_method
    self.class.submit_in_flight_original ||=
      Corvid::ClaimSubmission.instance_method(:submit_in_flight_claim!)
  end

  def restore_submit_in_flight_claim!
    original = self.class.submit_in_flight_original
    return unless original

    Corvid::ClaimSubmission.define_method(:submit_in_flight_claim!, original)
  end

  def restore_lock_spy!
    return unless Corvid::ClaimSubmission.method_defined?(:lock_without_override_marker_race)

    Corvid::ClaimSubmission.class_eval do
      alias_method :lock!, :lock_without_override_marker_race
      remove_method :lock_without_override_marker_race
    end
  end

  def inject_override_before_no_override_lock!(claim_id)
    injected = false
    original = self.class.submit_without_override_original ||=
      Corvid::ClaimSubmission.instance_method(:submit_without_override!)
    Corvid::ClaimSubmission.define_method(:submit_without_override!) do
      unless injected
        injected = true
        Corvid::ClaimSubmission.find(claim_id).override_medicaid_hold!(
          reason_token: "rt_concurrent_before_lock",
          by_identifier: "usr_concurrent_before_lock"
        )
      end
      original.bind_call(self)
    end
  end

  # Concurrent override from another process commits on its own connection;
  # the caller's rollback must not erase it.
  def inject_override_before_no_override_lock_on_peer_connection!(claim_id)
    injected = false
    tenant = TENANT
    original = self.class.submit_without_override_original ||=
      Corvid::ClaimSubmission.instance_method(:submit_without_override!)
    Corvid::ClaimSubmission.define_method(:submit_without_override!) do
      unless injected
        injected = true
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Corvid::TenantContext.with_tenant(tenant) do
              Corvid::ClaimSubmission.find(claim_id).override_medicaid_hold!(
                reason_token: "rt_concurrent_before_lock",
                by_identifier: "usr_concurrent_before_lock"
              )
            end
          end
        end.join(10)
      end
      original.bind_call(self)
    end
  end

  def restore_submit_without_override!
    original = self.class.submit_without_override_original
    return unless original

    Corvid::ClaimSubmission.define_method(:submit_without_override!, original)
  end

  def assert_raises_in_flight_submission_changed!
    error = assert_raises(StandardError) { yield }
    assert_in_flight_changed_message!(error)
    error
  end

  def in_flight_submission_changed_class
    Corvid::ClaimSubmission.const_get(:InFlightSubmissionChanged)
  end

  def assert_in_flight_changed_message!(error)
    assert error.is_a?(StandardError)
    assert_equal in_flight_submission_changed_class, error.class
    refute_match(/pt[-_]/i, error.message)
    refute_match(/TEST,PATIENT/i, error.message)
  end

  def claim_in_outcome_unknown_state!
    claim = held_draft_with_override!
    Corvid.adapter.define_singleton_method(:submit_claim) { |_data| raise StandardError, "send failed" }
    assert_raises(StandardError) { claim.submit! }
    fresh_claim_row(claim.id).tap { |row| assert submission_outcome_unknown_row?(row) }
    Corvid::ClaimSubmission.find(claim.id)
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
    referral = referral_at("fac_test", "REF-PHASEB-#{SecureRandom.hex(3)}")
    authorize!(referral)
    service_date = Date.new(2027, 2, 1)
    exhaust_alternate_resources!(referral, date_of_service: service_date, as_of: Time.current)
    referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(status: "not_enrolled")
    seed_patient_pending_medicaid_on_referral!(
      patient_id: referral.case.patient_identifier,
      referral_id: "REF-PEND-#{SecureRandom.hex(3)}",
      application_date: Date.new(2027, 3, 15),
      application_date_source: "staff_entry",
      medicaid_state_code: "XA",
      eligibility_group: "expansion_adult"
    )
    build_claim_for(referral, service_date: service_date).tap(&:save!)
  end

  def never_sent_draft_for_guard_pin!
    referral = referral_at("fac_test", "REF-DRAFT-GUARD-#{SecureRandom.hex(3)}")
    authorize!(referral)
    build_claim_for(referral).tap(&:save!)
  end

  def imported_never_sent_claim!(status:)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: "fac_import_pin",
      patient_identifier: "pt_import_#{status}_#{SecureRandom.hex(3)}",
      referral_identifier: "REF-IMPORT-#{status.upcase}-#{SecureRandom.hex(3)}",
      claim_type: "professional",
      service_date: Date.new(2027, 2, 1),
      billed_amount: 100.0,
      status: status
    )
  end

  def seed_patient_pending_medicaid_on_referral!(patient_id:, referral_id:, **medicaid_attrs)
    kase = Corvid::Case.create!(
      patient_identifier: patient_id,
      facility_identifier: "fac_test"
    )
    pending_referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: referral_id,
      facility_identifier: "fac_test"
    )
    medicaid = pending_referral.alternate_resource_checks.find_or_create_by!(resource_type: "medicaid") do |check|
      check.status = "not_checked"
    end
    medicaid.update!(
      status: "pending_enrollment",
      eligibility_group_source: "staff_entry",
      eligibility_group_set_at: Time.current,
      **medicaid_attrs
    )
    pending_referral
  end

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

  def referral_at(facility, identifier, patient: "TEST,PATIENT PHASEB-#{SecureRandom.hex(2)}")
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
      { claim_identifier: "CLM-PHASEB-#{calls.size}", status: "accepted" }
    end
    calls
  end
end
