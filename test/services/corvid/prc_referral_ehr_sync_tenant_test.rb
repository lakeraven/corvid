# frozen_string_literal: true

require "test_helper"

# Issue #668 / PR #689 pin 2: deferred EHR status sync runs in the decision's
# tenant context after the outer transaction commits.
class Corvid::PrcReferralEhrSyncTenantTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other_ehr"
  FACILITY = "fac_ehr_sync_tenant"
  PATIENT = "pt_ehr_sync_tenant"

  teardown do
    Corvid.reset_configuration!
    Corvid::TenantContext.reset!
  end

  test "mark_denied! deferred update_referral observes decision tenant when host tenant is unset outside block" do
    ehr_tenants = track_ehr_tenant_during_update_referral

    Corvid::TenantContext.reset!
    ActiveRecord::Base.transaction do
      with_tenant(TENANT) do
        referral = referral_in_eligibility_review!
        referral.mark_denied!
      end
    end

    assert_equal 1, ehr_tenants.size
    assert_equal TENANT, ehr_tenants.first,
      "EHR sync must run under decision tenant #{TENANT}, got #{ehr_tenants.inspect}"
  end

  test "authorize! deferred update_referral observes decision tenant when host tenant is wrong outside block" do
    ehr_tenants = track_ehr_tenant_during_update_referral

    Corvid::TenantContext.current_tenant_identifier = OTHER_TENANT
    ActiveRecord::Base.transaction do
      with_tenant(TENANT) do
        referral = referral_ready_to_authorize!
        assert referral.authorize!
      end
    end

    assert_equal 1, ehr_tenants.size
    assert_equal TENANT, ehr_tenants.first,
      "EHR sync must not run under outer tenant #{OTHER_TENANT}, got #{ehr_tenants.inspect}"
    refute_includes ehr_tenants, OTHER_TENANT
  end

  private

  def track_ehr_tenant_during_update_referral
    ehr_tenants = []
    Corvid.configure { |c| c.on_provenance = nil }
    adapter = Corvid.adapter
    original = adapter.method(:update_referral)
    adapter.define_singleton_method(:update_referral) do |identifier, **params|
      ehr_tenants << Corvid::TenantContext.current_tenant_identifier
      original.call(identifier, **params)
    end
    ehr_tenants
  end

  def referral_at(identifier)
    kase = Corvid::Case.create!(
      patient_identifier: PATIENT,
      facility_identifier: FACILITY
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: FACILITY,
      tenant_identifier: TENANT
    )
  end

  def referral_in_eligibility_review!
    referral = referral_at("REF-EHR-DENY-#{SecureRandom.hex(2)}")
    referral.submit!
    referral.begin_eligibility_review!
    referral.reload
  end

  def referral_ready_to_authorize!
    referral = referral_at("REF-EHR-AUTH-#{SecureRandom.hex(2)}")
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
end
