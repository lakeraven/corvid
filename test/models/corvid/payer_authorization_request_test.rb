# frozen_string_literal: true

require "test_helper"

class Corvid::PayerAuthorizationRequestTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"
  FACILITY = "fac_a"
  PAYER_A = "payer_a"
  PAYER_B = "payer_b"
  SIGNOFF = "pr_signoff_001"
  PAYER_AUTH_ID = "PAUTH-TEST-0001"
  PRC_AUTH_ON_REFERRAL = "PRC-AUTH-TEST-01"

  EXPECTED_CHANNELS = %w[pas x12_278 portal fax].freeze
  EXPECTED_STATUSES = %w[
    drafted submitted pended approved partially_approved denied cancelled
  ].freeze

  EXPECTED_COLUMNS = %w[
    id tenant_identifier facility_identifier prc_referral_id payer_identifier channel status
    submitted_at submitted_by_identifier follow_up_due_at payer_authorization_identifier
    approved_units approved_from approved_to lock_version created_at updated_at
  ].freeze

  NON_TERMINAL_TARGET_STATUSES = %w[
    drafted submitted pended approved partially_approved denied cancelled
  ].freeze

  FORBIDDEN_PHI_COLUMNS = %w[
    notes note reason rationale comment description patient_name display_name free_text
  ].freeze

  TRANSITION_METHODS = %w[submit! pend! approve! partially_approve! deny! cancel!].freeze

  ALLOWED_TRANSITIONS = {
    %w[drafted submit!] => "submitted",
    %w[drafted cancel!] => "cancelled",
    %w[submitted pend!] => "pended",
    %w[submitted approve!] => "approved",
    %w[submitted partially_approve!] => "partially_approved",
    %w[submitted deny!] => "denied",
    %w[submitted cancel!] => "cancelled",
    %w[pended approve!] => "approved",
    %w[pended partially_approve!] => "partially_approved",
    %w[pended deny!] => "denied",
    %w[pended cancel!] => "cancelled",
    %w[approved cancel!] => "cancelled",
    %w[partially_approved cancel!] => "cancelled"
  }.freeze

  teardown do
    Corvid.reset_configuration!
  end

  test "table is corvid_payer_authorization_requests" do
    assert_equal "corvid_payer_authorization_requests", Corvid::PayerAuthorizationRequest.table_name
  end

  test "includes TenantScoped" do
    assert_includes Corvid::PayerAuthorizationRequest.included_modules, Corvid::TenantScoped
  end

  test "queries without tenant context raise" do
    assert_raises(Corvid::MissingTenantContextError) do
      Corvid::PayerAuthorizationRequest.first
    end
  end

  test "column set matches ADR expectations without PHI text columns" do
    columns = Corvid::PayerAuthorizationRequest.column_names
    assert_equal EXPECTED_COLUMNS.sort, columns.sort
    FORBIDDEN_PHI_COLUMNS.each do |forbidden|
      refute_includes columns, forbidden, "must not store #{forbidden} at rest (ADR 0003)"
    end
  end

  test "CHANNELS constant lists allowed channels" do
    assert_equal EXPECTED_CHANNELS, Corvid::PayerAuthorizationRequest::CHANNELS
  end

  test "STATUSES constant lists allowed statuses" do
    assert_equal EXPECTED_STATUSES, Corvid::PayerAuthorizationRequest::STATUSES
  end

  test "defaults status to drafted" do
    with_tenant(TENANT) do
      request = build_request
      assert_equal "drafted", request.status
      assert request.persisted? || request.valid?
    end
  end

  test "new records must start drafted even when create! or save! names another status with full supporting fields" do
    non_drafted_statuses = EXPECTED_STATUSES - [ "drafted" ]

    with_tenant(TENANT) do
      non_drafted_statuses.each do |status|
        attrs = attrs_for_non_drafted_new_record(status)
        before_count = Corvid::PayerAuthorizationRequest.count

        error = assert_raises(ActiveRecord::RecordInvalid) do
          Corvid::PayerAuthorizationRequest.create!(attrs)
        end
        assert error.record.errors[:status].present?, "expected status error for #{status}"
        assert_equal before_count, Corvid::PayerAuthorizationRequest.count

        request = Corvid::PayerAuthorizationRequest.new(attrs_for_non_drafted_new_record(status))
        refute request.persisted?
        error = assert_raises(ActiveRecord::RecordInvalid) { request.save! }
        assert error.record.errors[:status].present?, "expected status error for #{status} on save!"
        refute request.persisted?
        assert_equal before_count, Corvid::PayerAuthorizationRequest.count
      end
    end
  end

  test "belongs_to prc_referral is optional" do
    with_tenant(TENANT) do
      request = Corvid::PayerAuthorizationRequest.create!(
        payer_identifier: PAYER_A,
        channel: "pas"
      )
      assert_nil request.prc_referral_id
    end
  end

  test "payer_authorization_turnarounds defaults to empty Hash" do
    assert_equal({}, Corvid.configuration.payer_authorization_turnarounds)
  end

  test "submit! sets follow_up_due_at from submitted at not wall clock now" do
    Corvid.configure { |c| c.payer_authorization_turnarounds = { PAYER_A => 3.days } }
    submitted_at = Time.utc(2026, 3, 2, 10, 0, 0)

    with_tenant(TENANT) do
      request = create_request(payer_identifier: PAYER_A)
      travel_to(Time.utc(2026, 3, 5, 10, 0, 0)) do
        request.submit!(submitted_by_identifier: SIGNOFF, at: submitted_at)
      end
      assert_equal Time.utc(2026, 3, 5, 10, 0, 0), request.follow_up_due_at
    end
  end

  test "submit! leaves follow_up_due_at nil when payer has no configured turnaround" do
    with_tenant(TENANT) do
      request = create_request(payer_identifier: PAYER_B)
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 2, 10, 0, 0))
      assert_nil request.follow_up_due_at
    end
  end

  test "submit! rejects blank submitted_by_identifier with ArgumentError and stays drafted" do
    with_tenant(TENANT) do
      request = create_request
      assert_raises(ArgumentError) { request.submit!(submitted_by_identifier: "", at: Time.current) }
      assert_equal "drafted", request.reload.status
      assert_nil request.submitted_at

      assert_raises(ArgumentError) { request.submit!(submitted_by_identifier: nil, at: Time.current) }
      assert_equal "drafted", request.reload.status
    end
  end

  test "submit! rejects non-Time at with ArgumentError and stays drafted" do
    with_tenant(TENANT) do
      request = create_request
      [ Date.new(2026, 3, 1), "2026-03-01" ].each do |bad_at|
        assert_raises(ArgumentError) { request.submit!(submitted_by_identifier: SIGNOFF, at: bad_at) }
        assert_equal "drafted", request.reload.status
        assert_nil request.reload.submitted_at
      end
    end
  end

  test "update! into submitted sets follow_up_due_at from payer turnaround and overdue includes row at due time" do
    Corvid.configure { |c| c.payer_authorization_turnarounds = { PAYER_A => 5.days } }
    submitted_at = Time.utc(2026, 3, 10, 14, 0, 0)
    due_at = Time.utc(2026, 3, 15, 14, 0, 0)

    with_tenant(TENANT) do
      request = create_request(payer_identifier: PAYER_A)
      request.update!(
        status: "submitted",
        submitted_at: submitted_at,
        submitted_by_identifier: SIGNOFF
      )
      assert_equal due_at, request.follow_up_due_at

      results = Corvid::PayerAuthorizationRequest.overdue(as_of: due_at)
      assert_includes results, request.reload
    end
  end

  test "approve! rejects invalid approval fields with ArgumentError and leaves row unchanged" do
    with_tenant(TENANT) do
      request = request_in("submitted")
      baseline_status = request.status

      assert_raises(ArgumentError) do
        request.approve!(payer_authorization_identifier: "", approved_from: Date.new(2026, 4, 1), approved_to: Date.new(2026, 4, 30))
      end
      assert_equal baseline_status, request.status
      assert_equal baseline_status, request.reload.status

      assert_raises(ArgumentError) do
        request.approve!(payer_authorization_identifier: PAYER_AUTH_ID, approved_from: nil, approved_to: Date.new(2026, 4, 30))
      end
      assert_equal baseline_status, request.status
      assert_equal baseline_status, request.reload.status

      assert_raises(ArgumentError) do
        request.approve!(
          payer_authorization_identifier: PAYER_AUTH_ID,
          approved_from: Date.new(2026, 4, 30),
          approved_to: Date.new(2026, 4, 1)
        )
      end
      assert_equal baseline_status, request.status
      assert_equal baseline_status, request.reload.status

      assert_raises(ArgumentError) do
        request.approve!(
          payer_authorization_identifier: PAYER_AUTH_ID,
          approved_from: Date.new(2026, 4, 1),
          approved_to: Date.new(2026, 4, 30),
          approved_units: 0
        )
      end
      assert_equal baseline_status, request.status
      assert_equal baseline_status, request.reload.status
    end
  end

  test "failed approve! transition leaves status submitted in memory and in the database" do
    with_tenant(TENANT) do
      request = request_in("submitted")

      assert_raises(ActiveRecord::RecordInvalid) do
        request.approve!(
          payer_authorization_identifier: PAYER_AUTH_ID,
          approved_from: Date.new(2026, 4, 1),
          approved_to: Date.new(2026, 4, 30),
          approved_units: 1.5
        )
      end
      assert_equal "submitted", request.status
      assert_equal "submitted", request.reload.status

      assert_raises(ArgumentError) do
        request.approve!(
          payer_authorization_identifier: PAYER_AUTH_ID,
          approved_from: "not-a-date",
          approved_to: Date.new(2026, 4, 30)
        )
      end
      assert_equal "submitted", request.status
      assert_equal "submitted", request.reload.status
    end
  end

  test "partially_approve! rejects invalid approval fields with ArgumentError and leaves row unchanged" do
    with_tenant(TENANT) do
      request = request_in("submitted")
      assert_raises(ArgumentError) do
        request.partially_approve!(
          payer_authorization_identifier: nil,
          approved_from: Date.new(2026, 4, 1),
          approved_to: Date.new(2026, 4, 30)
        )
      end
      assert_equal "submitted", request.reload.status
    end
  end

  test "direct status assignment with disallowed transition is invalid on status" do
    with_tenant(TENANT) do
      request = request_in("drafted")
      request.status = "approved"
      refute request.valid?
      assert request.errors[:status].present?
      assert_raises(ActiveRecord::RecordInvalid) { request.save! }
    end
  end

  test "terminal statuses cannot be changed through save or update!" do
    with_tenant(TENANT) do
      assert_terminal_save_blocked(request_in("denied"))
      assert_terminal_save_blocked(request_in("cancelled"))

      approved = request_in("approved")
      disallowed_target_statuses("approved").each do |target_status|
        assert_direct_status_update_invalid(approved, target_status)
      end
    end
  end

  test "lock_version column enables optimistic locking on concurrent saves" do
    column = Corvid::PayerAuthorizationRequest.columns_hash.fetch("lock_version")
    assert_equal :integer, column.type
    assert column.null == false, "lock_version must be NOT NULL"
    assert column.default.nil? || column.default.to_i == 0, "lock_version default must cast to 0"

    with_tenant(TENANT) do
      assert_equal 0, Corvid::PayerAuthorizationRequest.new.lock_version
      request = request_in("submitted")
      stale_copy = Corvid::PayerAuthorizationRequest.find(request.id)
      fresh_copy = Corvid::PayerAuthorizationRequest.find(request.id)

      fresh_copy.deny!
      assert_equal "denied", request.reload.status

      assert_raises(ActiveRecord::StaleObjectError) do
        stale_copy.update!(
          status: "approved",
          payer_authorization_identifier: PAYER_AUTH_ID,
          approved_from: Date.new(2026, 4, 1),
          approved_to: Date.new(2026, 4, 30)
        )
      end
      assert_equal "denied", stale_copy.reload.status

      submitted = request_in("submitted")
      stale_approved = Corvid::PayerAuthorizationRequest.find(submitted.id)
      stale_for_update = Corvid::PayerAuthorizationRequest.find(submitted.id)
      Corvid::PayerAuthorizationRequest.find(submitted.id).approve!(
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: Date.new(2026, 5, 1),
        approved_to: Date.new(2026, 5, 31)
      )

      assert_raises(Corvid::PayerAuthorizationRequest::InvalidTransition) do
        stale_approved.deny!
      end
      assert_equal "approved", stale_approved.reload.status

      assert_raises(ActiveRecord::StaleObjectError) do
        stale_for_update.update!(status: "denied")
      end
      assert_equal "approved", stale_for_update.reload.status
    end
  end

  test "InvalidTransition is a StandardError subclass with from and to in message" do
    assert_operator Corvid::PayerAuthorizationRequest::InvalidTransition, :<, StandardError

    with_tenant(TENANT) do
      request = request_in("drafted")
      error = assert_raises(Corvid::PayerAuthorizationRequest::InvalidTransition) do
        request.pend!
      end
      assert_match(/drafted/i, error.message)
      assert_match(/pended/i, error.message)
    end
  end

  test "prc_referral from another tenant is invalid" do
    other_referral = nil
    with_tenant(OTHER_TENANT) do
      other_referral = create_referral
    end

    with_tenant(TENANT) do
      request = build_request(prc_referral: other_referral)
      refute request.valid?
      assert request.errors[:prc_referral].present?
    end
  end

  test "facility_identifier must match linked referral when referral has one" do
    with_tenant(TENANT) do
      referral = create_referral(facility_identifier: FACILITY)
      request = build_request(prc_referral: referral, facility_identifier: "fac_mismatch")
      refute request.valid?
      assert request.errors[:facility_identifier].present? || request.errors[:prc_referral].present?
    end
  end

  test "facility_identifier must match linked referral when request facility is nil" do
    with_tenant(TENANT) do
      referral = create_referral(facility_identifier: FACILITY)
      request = build_request(prc_referral: referral, facility_identifier: nil)
      refute request.valid?
      assert request.errors[:facility_identifier].present?
    end
  end

  test "referral with nil facility accepts any request facility_identifier" do
    with_tenant(TENANT) do
      referral = create_referral(facility_identifier: nil)
      request = build_request(prc_referral: referral, facility_identifier: FACILITY)
      assert request.valid?, request.errors.full_messages.join(", ")
    end
  end

  test "non-existent prc_referral_id is invalid" do
    with_tenant(TENANT) do
      request = build_request
      request.prc_referral_id = 9_999_999_999
      refute request.valid?
      assert request.errors[:prc_referral].present?
    end
  end

  test "unsaved prc_referral from another tenant makes save invalid and persists neither row" do
    other_case = nil
    with_tenant(OTHER_TENANT) do
      other_case = Corvid::Case.create!(
        patient_identifier: "pt_pauth_other_#{SecureRandom.hex(3)}",
        facility_identifier: FACILITY
      )
    end

    with_tenant(TENANT) do
      unsaved_other_referral = Corvid::PrcReferral.new(
        tenant_identifier: OTHER_TENANT,
        case: other_case,
        referral_identifier: "rf_pauth_unsaved_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY
      )
      request = build_request(prc_referral: unsaved_other_referral)

      assert_raises(ActiveRecord::RecordInvalid) { request.save! }
      assert request.errors[:prc_referral].present?
      refute request.persisted?
      refute unsaved_other_referral.persisted?
    end
  end

  test "database rejects prc_referral_id from another tenant via update_columns" do
    other_referral = nil
    with_tenant(OTHER_TENANT) do
      other_referral = create_referral
    end

    with_tenant(TENANT) do
      request = create_request
      assert_raises(ActiveRecord::StatementInvalid) do
        request.update_columns(prc_referral_id: other_referral.id)
      end
      assert_nil request.reload.prc_referral_id
    end
  end

  test "approve! does not write payer authorization number onto PRC referral authorization_number" do
    with_tenant(TENANT) do
      referral = create_referral(authorization_number: PRC_AUTH_ON_REFERRAL)
      request = create_request(prc_referral: referral)
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 12, 0, 0))
      request.approve!(
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: Date.new(2026, 4, 1),
        approved_to: Date.new(2026, 4, 30)
      )
      assert_equal PRC_AUTH_ON_REFERRAL, referral.reload.authorization_number
    end
  end

  test "approve! leaves nil PRC referral authorization_number nil" do
    with_tenant(TENANT) do
      referral = create_referral(authorization_number: nil)
      request = create_request(prc_referral: referral)
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 12, 0, 0))
      request.approve!(
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: Date.new(2026, 4, 1),
        approved_to: Date.new(2026, 4, 30)
      )
      assert_nil referral.reload.authorization_number
    end
  end

  test "partially_approve! does not write payer authorization number onto PRC referral authorization_number" do
    with_tenant(TENANT) do
      referral = create_referral(authorization_number: PRC_AUTH_ON_REFERRAL)
      request = create_request(prc_referral: referral)
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 12, 0, 0))
      request.partially_approve!(
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: Date.new(2026, 4, 1),
        approved_to: Date.new(2026, 4, 30)
      )
      assert_equal PRC_AUTH_ON_REFERRAL, referral.reload.authorization_number
    end
  end

  test "partially_approve! leaves nil PRC referral authorization_number nil" do
    with_tenant(TENANT) do
      referral = create_referral(authorization_number: nil)
      request = create_request(prc_referral: referral)
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 12, 0, 0))
      request.partially_approve!(
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: Date.new(2026, 4, 1),
        approved_to: Date.new(2026, 4, 30)
      )
      assert_nil referral.reload.authorization_number
    end
  end

  test "submission evidence is immutable after the payer was asked on submitted pended and denied rows" do
    with_tenant(TENANT) do
      %w[submitted pended denied].each do |status|
        assert_submission_evidence_immutable(request_in(status))
      end
    end
  end

  test "approval evidence is immutable after approve or partially_approve including after cancel!" do
    with_tenant(TENANT) do
      assert_approval_evidence_immutable(request_in("approved"))
      assert_approval_evidence_immutable(request_in("partially_approved"))

      cancelled_after_approval = request_in("approved")
      cancelled_after_approval.cancel!
      assert_approval_evidence_immutable(cancelled_after_approval.reload)
    end
  end

  test "non-decided rows may not carry approval fields on update!" do
    approval_patch = {
      payer_authorization_identifier: PAYER_AUTH_ID,
      approved_from: Date.new(2026, 4, 1),
      approved_to: Date.new(2026, 4, 30)
    }

    with_tenant(TENANT) do
      %w[denied submitted pended].each do |status|
        request = request_in(status)
        baseline_status = request.status
        assert_raises(ActiveRecord::RecordInvalid) { request.update!(approval_patch) }
        assert_equal baseline_status, request.reload.status
        refute request.payer_authorization_identifier.present?
      end
    end
  end

  test "overdue includes submitted and pended rows due on or before as_of for current tenant only" do
    as_of = Time.utc(2026, 5, 10, 15, 0, 0)
    due_on_boundary = as_of
    due_one_second_later = as_of + 1.second

    with_tenant(OTHER_TENANT) do
      create_request_with_follow_up(status: "submitted", follow_up_due_at: due_on_boundary)
    end

    with_tenant(TENANT) do
      on_boundary = create_request_with_follow_up(status: "submitted", follow_up_due_at: due_on_boundary)
      pended_overdue = create_request_with_follow_up(status: "pended", follow_up_due_at: due_on_boundary)
      not_yet = create_request_with_follow_up(status: "pended", follow_up_due_at: due_one_second_later)
      no_timer = create_request(payer_identifier: PAYER_B)
      no_timer.submit!(submitted_by_identifier: SIGNOFF, at: as_of - 1.day)
      drafted = create_request
      denied = request_in("denied")
      cancelled = request_in("cancelled")

      results = Corvid::PayerAuthorizationRequest.overdue(as_of: as_of)
      expected_ids = [ on_boundary.id, pended_overdue.id ].sort

      assert_includes results, on_boundary
      assert_includes results, pended_overdue
      refute_includes results, not_yet
      refute_includes results, no_timer
      refute_includes results, drafted
      refute_includes results, denied
      refute_includes results, cancelled
      assert_empty results.where(tenant_identifier: OTHER_TENANT)
      assert_equal expected_ids, results.map(&:id).sort
    end
  end

  test "expiring returns approved and partially_approved rows expiring within window for current tenant only" do
    as_of = Date.new(2026, 6, 1)
    within = 7.days

    with_tenant(OTHER_TENANT) do
      create_decided_request(
        status: "approved",
        approved_from: as_of,
        approved_to: as_of + 3.days
      )
    end

    with_tenant(TENANT) do
      lower_bound = create_decided_request(status: "approved", approved_from: as_of - 10.days, approved_to: as_of)
      upper_bound = create_decided_request(
        status: "partially_approved",
        approved_from: as_of,
        approved_to: as_of + within
      )
      before_window = create_decided_request(
        status: "approved",
        approved_from: as_of - 20.days,
        approved_to: as_of - 1.day
      )
      after_window = create_decided_request(
        status: "approved",
        approved_from: as_of,
        approved_to: as_of + within + 1.day
      )
      denied = request_in("denied")
      cancelled = request_in("cancelled")

      results = Corvid::PayerAuthorizationRequest.expiring(within: within, as_of: as_of)
      expected_ids = [ lower_bound.id, upper_bound.id ].sort

      assert_includes results, lower_bound
      assert_includes results, upper_bound
      refute_includes results, before_window
      refute_includes results, after_window
      refute_includes results, denied
      refute_includes results, cancelled
      assert_empty results.where(tenant_identifier: OTHER_TENANT)
      assert_equal expected_ids, results.map(&:id).sort
    end
  end

  test "overdue rejects Date as_of because midnight would skew boundaries" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) do
        Corvid::PayerAuthorizationRequest.overdue(as_of: Date.new(2026, 5, 10))
      end
    end
  end

  EXPECTED_STATUSES.product(TRANSITION_METHODS).each do |from_status, method|
    test "transition #{method} from #{from_status}" do
      with_tenant(TENANT) do
        request = request_in(from_status)
        before_status = request.status

        expected = ALLOWED_TRANSITIONS[[ from_status, method ]]

        if expected
          result = apply_transition!(request, method)
          assert_same request, result
          assert_equal expected, request.reload.status
        else
          assert_raises(Corvid::PayerAuthorizationRequest::InvalidTransition) do
            apply_transition!(request, method)
          end
          assert_equal before_status, request.reload.status
        end
      end
    end
  end

  private

  def attrs_for_non_drafted_new_record(status)
    base = {
      payer_identifier: PAYER_A,
      channel: "pas",
      facility_identifier: FACILITY,
      status: status
    }
    case status
    when "submitted", "pended", "denied"
      base.merge(
        submitted_at: Time.utc(2026, 3, 1, 10, 0, 0),
        submitted_by_identifier: SIGNOFF
      )
    when "approved", "partially_approved"
      base.merge(
        submitted_at: Time.utc(2026, 3, 1, 10, 0, 0),
        submitted_by_identifier: SIGNOFF,
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: Date.new(2026, 4, 1),
        approved_to: Date.new(2026, 4, 30)
      )
    when "cancelled"
      base
    else
      raise ArgumentError, "unexpected status: #{status}"
    end
  end

  def assert_submission_evidence_immutable(request)
    baseline = request.attributes.slice("submitted_at", "submitted_by_identifier", "follow_up_due_at")
    copy = Corvid::PayerAuthorizationRequest.find(request.id)
    copy.submitted_at = baseline.fetch("submitted_at") + 1.hour if baseline.fetch("submitted_at")
    copy.submitted_by_identifier = "pr_other_signoff"
    copy.follow_up_due_at = Time.utc(2099, 1, 1, 12, 0, 0)

    assert_raises(ActiveRecord::RecordInvalid) { copy.save! }
    assert_equal baseline, request.reload.attributes.slice("submitted_at", "submitted_by_identifier", "follow_up_due_at")
  end

  def assert_approval_evidence_immutable(request)
    baseline = request.attributes.slice(
      "payer_authorization_identifier", "approved_from", "approved_to", "approved_units"
    )
    copy = Corvid::PayerAuthorizationRequest.find(request.id)
    copy.payer_authorization_identifier = "PAUTH-IMMUTABLE-OTHER"
    copy.approved_from = Date.new(2099, 1, 1)
    copy.approved_to = Date.new(2099, 12, 31)
    copy.approved_units = 99

    assert_raises(ActiveRecord::RecordInvalid) { copy.save! }
    assert_equal baseline, request.reload.attributes.slice(
      "payer_authorization_identifier", "approved_from", "approved_to", "approved_units"
    )
  end

  def build_request(**attrs)
    defaults = {
      payer_identifier: PAYER_A,
      channel: "pas",
      facility_identifier: FACILITY
    }
    Corvid::PayerAuthorizationRequest.new(defaults.merge(attrs))
  end

  def create_request(**attrs)
    build_request(**attrs).tap(&:save!)
  end

  def create_referral(facility_identifier: FACILITY, authorization_number: nil)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_pauth_#{SecureRandom.hex(3)}",
      facility_identifier: facility_identifier || FACILITY
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "rf_pauth_#{SecureRandom.hex(4)}",
      facility_identifier: facility_identifier,
      authorization_number: authorization_number
    )
  end

  def assert_terminal_save_blocked(request)
    baseline = request.attributes.slice("status", "payer_authorization_identifier", "approved_from", "approved_to")
    disallowed_target_statuses(request.status).each do |target_status|
      assert_direct_status_update_invalid(request, target_status)
    end
    request.reload
    assert_equal baseline, request.attributes.slice("status", "payer_authorization_identifier", "approved_from", "approved_to")
  end

  def disallowed_target_statuses(from_status)
    NON_TERMINAL_TARGET_STATUSES.reject do |target_status|
      target_status == from_status ||
        Corvid::PayerAuthorizationRequest.transition_allowed?(from_status, target_status)
    end
  end

  def assert_direct_status_update_invalid(request, target_status)
    attrs = { status: target_status }
    if Corvid::PayerAuthorizationRequest::APPROVAL_STATUSES.include?(target_status)
      attrs.merge!(
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: Date.new(2026, 4, 1),
        approved_to: Date.new(2026, 4, 30)
      )
    end
    if Corvid::PayerAuthorizationRequest::SUBMISSION_STATUSES.include?(target_status)
      attrs[:submitted_at] = Time.utc(2026, 3, 1, 10, 0, 0)
      attrs[:submitted_by_identifier] = SIGNOFF
    end

    copy = Corvid::PayerAuthorizationRequest.find(request.id)
    assert_raises(ActiveRecord::RecordInvalid) { copy.update!(attrs) }
    assert copy.errors[:status].present?
    assert_equal request.reload.status, copy.reload.status
  end

  def approval_kwargs
    {
      payer_authorization_identifier: PAYER_AUTH_ID,
      approved_from: Date.new(2026, 4, 1),
      approved_to: Date.new(2026, 4, 30)
    }
  end

  def request_in(status)
    request = create_request
    case status
    when "drafted"
      request
    when "submitted"
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 9, 0, 0))
      request.reload
    when "pended"
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 9, 0, 0))
      request.pend!
      request.reload
    when "approved"
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 9, 0, 0))
      request.approve!(**approval_kwargs)
      request.reload
    when "partially_approved"
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 9, 0, 0))
      request.partially_approve!(**approval_kwargs)
      request.reload
    when "denied"
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 9, 0, 0))
      request.deny!
      request.reload
    when "cancelled"
      request.cancel!
      request.reload
    else
      raise ArgumentError, "unknown status fixture: #{status}"
    end
  end

  def apply_transition!(request, method)
    case method
    when "submit!"
      request.submit!(submitted_by_identifier: SIGNOFF, at: Time.current)
    when "pend!"
      request.pend!
    when "approve!"
      request.approve!(**approval_kwargs)
    when "partially_approve!"
      request.partially_approve!(**approval_kwargs)
    when "deny!"
      request.deny!
    when "cancel!"
      request.cancel!
    else
      raise ArgumentError, method
    end
  end

  def create_request_with_follow_up(status:, follow_up_due_at:)
    request = create_request
    request.submit!(submitted_by_identifier: SIGNOFF, at: follow_up_due_at - 3.days)
    request.pend! if status == "pended"
    request.update_columns(follow_up_due_at: follow_up_due_at, status: status)
    request.reload
  end

  def create_decided_request(status:, approved_from:, approved_to:)
    request = create_request
    request.submit!(submitted_by_identifier: SIGNOFF, at: Time.utc(2026, 3, 1, 9, 0, 0))
    if status == "approved"
      request.approve!(
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: approved_from,
        approved_to: approved_to
      )
    else
      request.partially_approve!(
        payer_authorization_identifier: PAYER_AUTH_ID,
        approved_from: approved_from,
        approved_to: approved_to
      )
    end
    request.reload
  end
end
