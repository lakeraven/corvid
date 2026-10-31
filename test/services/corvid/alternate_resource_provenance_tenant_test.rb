# frozen_string_literal: true

require "test_helper"

# Issue #668 pin C: deferred provenance delivery runs in the tenant context of
# the decision (TenantContext at hook invocation).
class Corvid::AlternateResourceProvenanceTenantTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"
  FACILITY = "fac_tenant_prov"
  PATIENT = "pt-tenant-prov"

  setup do
    record_system_of_record(facility_identifier: FACILITY, tenant_identifier: TENANT)
  end

  teardown do
    Corvid.reset_configuration!
    Corvid::TenantContext.reset!
  end

  test "authorize! on_provenance runs under decision tenant when host tenant is unset outside block" do
    hook_tenants = []
    Corvid.configure do |c|
      c.on_provenance = ->(**_attrs) {
        hook_tenants << Corvid::TenantContext.current_tenant_identifier
      }
    end

    Corvid::TenantContext.reset!
    ActiveRecord::Base.transaction do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        assert referral.authorize!
      end
    end

    assert_equal 1, hook_tenants.size
    assert_equal TENANT, hook_tenants.first,
      "provenance hook must observe decision tenant #{TENANT}, got #{hook_tenants.inspect}"
  end

  test "authorize! on_provenance runs under decision tenant when host tenant is wrong outside block" do
    hook_tenants = []
    Corvid.configure do |c|
      c.on_provenance = ->(**_attrs) {
        hook_tenants << Corvid::TenantContext.current_tenant_identifier
      }
    end

    Corvid::TenantContext.current_tenant_identifier = OTHER_TENANT
    ActiveRecord::Base.transaction do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        assert referral.authorize!
      end
    end

    assert_equal 1, hook_tenants.size
    assert_equal TENANT, hook_tenants.first,
      "provenance hook must not run under outer tenant #{OTHER_TENANT}, got #{hook_tenants.inspect}"
    refute_includes hook_tenants, OTHER_TENANT
  end

  test "claim submit! on_provenance runs under decision tenant when host tenant is unset outside block" do
    hook_tenants = []
    Corvid.configure { |c| c.on_provenance = nil }

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at(FACILITY, "REF-TENANT-CLAIM")
        authorize_referral_without_provenance!(referral)
        claim = build_claim(
          facility: FACILITY,
          referral_identifier: "REF-TENANT-CLAIM",
          patient: referral.case.patient_identifier,
          service_date: Date.new(2025, 6, 10)
        )
        claim.save!
      end
    end

    Corvid.configure do |c|
      c.on_provenance = ->(**_attrs) {
        hook_tenants << Corvid::TenantContext.current_tenant_identifier
      }
    end

    Corvid::TenantContext.reset!
    ActiveRecord::Base.transaction do
      with_tenant(TENANT) do
        travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
          claim = Corvid::ClaimSubmission.find_by!(referral_identifier: "REF-TENANT-CLAIM")
          referral = claim.prc_referral.reload
          exhaust_alternate_resources!(
            referral,
            date_of_service: Date.new(2025, 6, 10),
            as_of: Time.current
          )
          claim.reload
          claim.submit!
        end
      end
    end

    assert_equal 1, hook_tenants.size
    assert_equal TENANT, hook_tenants.first
  end

  private

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: PATIENT,
      facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: facility,
      tenant_identifier: TENANT
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

  def referral_ready_to_authorize!
    referral = referral_at(FACILITY, "REF-TENANT-AUTH-#{SecureRandom.hex(3)}")
    referral.submit!
    referral.begin_eligibility_review!
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
    referral.pending_approval_by = "usr_other"
    referral.approve_management!
    exhaust_alternate_resources!(referral)
    referral.verify_alternate_resources!
    referral.update!(medical_priority: 3, estimated_cost: 75_000)
    referral.complete_priority_assignment!
    assert referral.committee_review?
    referral.reload
  end

  def authorize_referral_without_provenance!(referral)
    Corvid.configure { |c| c.on_provenance = nil }
    referral.submit! if referral.may_submit?
    referral.begin_eligibility_review! if referral.may_begin_eligibility_review?
    checklist = referral.eligibility_checklist
    Corvid::EligibilityChecklist::NON_APPROVAL_ITEMS.each do |item|
      fields = Corvid::EligibilityChecklist::ITEM_FIELDS.fetch(item)
      kwargs = {}
      kwargs[:source] = "test_fixture" if fields.key?(:source)
      kwargs[:by] = "usr_submitter" if fields.key?(:by)
      checklist.verify_item!(item, **kwargs)
    end
    referral.reload
    referral.request_management_approval! if referral.may_request_management_approval?
    referral.pending_approval_by = "usr_other"
    referral.approve_management! if referral.may_approve_management?
    exhaust_alternate_resources!(referral, date_of_service: Date.new(2025, 6, 10), as_of: Time.zone.parse("2025-06-15 12:00:00 UTC"))
    referral.verify_alternate_resources! if referral.may_verify_alternate_resources?
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.complete_priority_assignment! if referral.may_complete_priority_assignment?
    referral.authorize! if referral.may_authorize?
    referral.reload
  end
end
