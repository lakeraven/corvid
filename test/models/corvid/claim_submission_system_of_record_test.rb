# frozen_string_literal: true

require "test_helper"

class Corvid::ClaimSubmissionSystemOfRecordTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"
  FACILITY = "fac_a"
  SERVICE_DATE = Date.new(2025, 4, 10)

  NOT_SYSTEM_OF_RECORD_MESSAGE =
    "This claim cannot be submitted because Corvid is not the billing system of record."
  SYSTEM_OF_RECORD_UNSET_MESSAGE =
    "This claim cannot be submitted because no billing system of record is configured."

  setup do
    @submit_claim_calls = []
    recorder = @submit_claim_calls
    Corvid.adapter.define_singleton_method(:submit_claim) do |claim_data|
      recorder << claim_data
      { claim_identifier: "CLM-SOR-#{recorder.size}", status: "accepted" }
    end
  end

  test "SystemOfRecordRefused is a StandardError with generic messages per reason" do
    error_class = Corvid::ClaimSubmission::SystemOfRecordRefused
    assert error_class < StandardError

    not_sor = error_class.new(:not_system_of_record)
    assert_equal :not_system_of_record, not_sor.reason
    assert_equal NOT_SYSTEM_OF_RECORD_MESSAGE, not_sor.message
    refute_match(/fac_|tnt_|pt_|CLM-/i, not_sor.message)

    unset = error_class.new(:system_of_record_unset)
    assert_equal :system_of_record_unset, unset.reason
    assert_equal SYSTEM_OF_RECORD_UNSET_MESSAGE, unset.message
    refute_match(/fac_|tnt_|pt_|CLM-/i, unset.message)
  end

  test "submit! proceeds when Corvid is system of record" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY, system_of_record: "corvid")
      claim = create_draft_claim(facility: FACILITY, service_date: Date.new(2025, 4, 10))

      claim.submit!

      assert_equal 1, @submit_claim_calls.size
      claim.reload
      assert_equal "submitted", claim.status
      assert_equal "CLM-SOR-1", claim.claim_identifier
      assert_not_nil claim.submitted_at
    end
  end

  test "submit! refuses when EHR is system of record" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY, system_of_record: "ehr")
      claim = create_draft_claim(facility: FACILITY, service_date: Date.new(2025, 4, 10))
      before = claim.attributes.slice("status", "claim_identifier", "submitted_at")

      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { claim.submit! }

      assert_equal :not_system_of_record, error.reason
      assert_equal NOT_SYSTEM_OF_RECORD_MESSAGE, error.message
      assert_equal 0, @submit_claim_calls.size
      assert_equal before, claim.reload.attributes.slice("status", "claim_identifier", "submitted_at")
    end
  end

  test "submit! refuses when no billing system of record is configured" do
    with_tenant(TENANT) do
      claim = create_draft_claim(facility: FACILITY, service_date: Date.new(2025, 4, 10))

      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { claim.submit! }

      assert_equal :system_of_record_unset, error.reason
      assert_equal SYSTEM_OF_RECORD_UNSET_MESSAGE, error.message
      assert_equal 0, @submit_claim_calls.size
      assert_equal "draft", claim.reload.status
      assert_nil claim.claim_identifier
      assert_nil claim.submitted_at
    end
  end

  test "submit! refuses untyped claim when a visit-type row names a different system than all-visits corvid" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY, system_of_record: "corvid")
      record_system_of_record(
        facility_identifier: FACILITY, visit_type: "dental", system_of_record: "ehr"
      )
      claim = create_draft_claim(facility: FACILITY, service_date: Date.new(2025, 4, 10))

      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { claim.submit! }

      assert_equal :system_of_record_unset, error.reason
      assert_equal 0, @submit_claim_calls.size
    end
  end

  test "submit! refuses when the only applicable setting starts after the service date" do
    with_tenant(TENANT) do
      service_date = Date.new(2025, 4, 10)
      record_system_of_record(
        facility_identifier: FACILITY,
        system_of_record: "corvid",
        effective_on: service_date + 1.day
      )
      claim = create_draft_claim(facility: FACILITY, service_date: service_date)

      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { claim.submit! }

      assert_equal :system_of_record_unset, error.reason
      assert_equal 0, @submit_claim_calls.size
    end
  end

  test "submit! refuses when service_date or facility_identifier is missing" do
    with_tenant(TENANT) do
      record_system_of_record(facility_identifier: FACILITY, system_of_record: "corvid")

      no_date = create_draft_claim(facility: FACILITY, service_date: Date.new(2025, 4, 10))
      no_date.update_columns(service_date: nil)
      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { no_date.submit! }
      assert_equal :system_of_record_unset, error.reason

      no_facility = create_draft_claim(facility: FACILITY, service_date: Date.new(2025, 4, 10))
      no_facility.update_columns(facility_identifier: nil)
      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { no_facility.submit! }
      assert_equal :system_of_record_unset, error.reason

      assert_equal 0, @submit_claim_calls.size
    end
  end

  test "submit! runs system-of-record gate before referral authorization" do
    with_tenant(TENANT) do
      referral = referral_at(FACILITY, "REF-SOR-ORDER")
      claim = build_claim(
        facility: FACILITY,
        referral_identifier: "REF-SOR-ORDER",
        patient: referral.case.patient_identifier,
        service_date: Date.new(2025, 4, 10)
      )
      claim.save!

      assert_equal "draft", referral.reload.status

      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { claim.submit! }

      assert_equal :system_of_record_unset, error.reason
      assert_equal 0, @submit_claim_calls.size
    end
  end

  test "mark_submitted! is not gated by billing system of record" do
    with_tenant(TENANT) do
      claim = create_draft_claim(facility: FACILITY, service_date: Date.new(2025, 4, 10))

      claim.mark_submitted!(claim_identifier: "CLM-EXTERNAL-791")

      assert_equal "submitted", claim.reload.status
      assert_equal "CLM-EXTERNAL-791", claim.claim_identifier
      assert_not_nil claim.submitted_at
      assert_equal 0, @submit_claim_calls.size
    end
  end

  test "submit! ignores another tenant's corvid setting" do
    record_system_of_record(
      facility_identifier: FACILITY,
      tenant_identifier: OTHER_TENANT,
      system_of_record: "corvid"
    )
    claim = with_tenant(TENANT) do
      create_draft_claim(facility: FACILITY, service_date: SERVICE_DATE)
    end
    before = claim_snapshot(claim.id)

    with_tenant(OTHER_TENANT) do
      claim_in_context = Corvid::ClaimSubmission.unscoped.find(claim.id)
      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { claim_in_context.submit! }

      assert_equal :system_of_record_unset, error.reason
    end

    assert_equal 0, @submit_claim_calls.size
    assert_equal before, claim_snapshot(claim.id)
  end

  test "submit! uses the claim's own ehr setting even inside another tenant's context" do
    record_system_of_record(
      facility_identifier: FACILITY,
      tenant_identifier: TENANT,
      system_of_record: "ehr"
    )
    record_system_of_record(
      facility_identifier: FACILITY,
      tenant_identifier: OTHER_TENANT,
      system_of_record: "corvid"
    )
    claim = with_tenant(TENANT) do
      create_draft_claim(facility: FACILITY, service_date: SERVICE_DATE)
    end

    with_tenant(OTHER_TENANT) do
      claim_in_context = Corvid::ClaimSubmission.unscoped.find(claim.id)
      error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { claim_in_context.submit! }

      assert_equal :not_system_of_record, error.reason
    end

    assert_equal 0, @submit_claim_calls.size
  end

  test "submit! uses the claim's own corvid setting even inside another tenant's context" do
    record_system_of_record(
      facility_identifier: FACILITY,
      tenant_identifier: TENANT,
      system_of_record: "corvid"
    )
    record_system_of_record(
      facility_identifier: FACILITY,
      tenant_identifier: OTHER_TENANT,
      system_of_record: "ehr"
    )
    claim = with_tenant(TENANT) do
      create_draft_claim(facility: FACILITY, service_date: SERVICE_DATE)
    end

    with_tenant(OTHER_TENANT) do
      claim_in_context = Corvid::ClaimSubmission.unscoped.find(claim.id)
      claim_in_context.submit!
    end

    assert_equal 1, @submit_claim_calls.size
    submitted = Corvid::ClaimSubmission.unscoped.find(claim.id)
    assert_equal "submitted", submitted.status
    assert_equal OTHER_TENANT, Corvid::TenantContext.current_tenant_identifier
  end

  test "submit! with no tenant context still reads the claim's own setting" do
    record_system_of_record(
      facility_identifier: FACILITY,
      tenant_identifier: TENANT,
      system_of_record: "ehr"
    )
    record_system_of_record(
      facility_identifier: FACILITY,
      tenant_identifier: OTHER_TENANT,
      system_of_record: "corvid"
    )
    claim = with_tenant(TENANT) do
      create_draft_claim(facility: FACILITY, service_date: SERVICE_DATE)
    end

    Corvid::TenantContext.reset!
    claim_without_context = Corvid::ClaimSubmission.unscoped.find(claim.id)
    error = assert_raises(Corvid::ClaimSubmission::SystemOfRecordRefused) { claim_without_context.submit! }

    assert_equal :not_system_of_record, error.reason
    assert_equal 0, @submit_claim_calls.size
  end

  private

  def claim_snapshot(claim_id)
    Corvid::ClaimSubmission.unscoped.find(claim_id).attributes.slice(
      "status", "claim_identifier", "submitted_at"
    )
  end

  def create_draft_claim(facility:, service_date:, **attrs)
    Corvid::ClaimSubmission.create!(
      patient_identifier: "pt_001",
      claim_type: "professional",
      facility_identifier: facility,
      service_date: service_date,
      status: "draft",
      billed_amount: 100.0,
      **attrs
    )
  end

  def build_claim(facility:, referral_identifier:, patient:, service_date:)
    Corvid::ClaimSubmission.new(
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

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_#{identifier}_#{SecureRandom.hex(3)}",
      facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: facility
    )
  end
end
