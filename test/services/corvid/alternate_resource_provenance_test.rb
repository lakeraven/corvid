# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Issue #668 (D): provenance for alternate resource checks relied on at decision time.
class Corvid::AlternateResourceProvenanceTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  FACILITY = "fac_test"
  PATIENT = "pt-test-004"

  teardown do
    Corvid.reset_configuration!
  end

  test "authorize! records alternate resource entities via on_provenance without PHI" do
    captured = nil
    Corvid.configure do |c|
      c.on_provenance = ->(**attrs) { captured = attrs }
    end

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = authorized_referral_ready_to_authorize!
        assert referral.authorize!

        refute_nil captured
        assert_equal "Corvid::PrcReferral", captured[:target_type]
        assert_equal referral.id.to_s, captured[:target_id]
        assert_equal "UPDATE", captured[:activity]
        assert captured[:recorded].present?

        entities = captured[:entities]
        refute_nil entities
        assert_equal Corvid::AlternateResourceCheck::RESOURCE_TYPES.size, entities.size

        sample = entities.find { |e| e[:resource_type] == "medicaid" }
        refute_nil sample
        %i[id resource_type status checked_at coverage_start coverage_end renewal_date].each do |key|
          assert sample.key?(key), "expected #{key} on provenance entity"
        end

        payload = captured.values + entities.flat_map(&:values)
        refute payload.any? { |v| v.to_s.match?(/pt-test|TEST,PATIENT/i) },
          "provenance must not include patient identifiers"
        refute payload.any? { |v| v.to_s.match?(/policy|payer/i) },
          "provenance must not include payer or policy fields"
      end
    end
  end

  test "successful claim submit! records alternate resource entities via on_provenance" do
    captured = nil
    Corvid.configure do |c|
      c.on_provenance = ->(**attrs) { captured = attrs }
    end

    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at("fac_a", "REF-PROV-CLAIM")
        authorize_referral!(referral)
        service_date = Date.new(2025, 6, 10)
        claim = build_claim(
          facility: "fac_a",
          referral_identifier: "REF-PROV-CLAIM",
          patient: referral.case.patient_identifier,
          service_date: service_date
        )
        claim.save!
        claim.submit!

        refute_nil captured
        assert_equal "Corvid::ClaimSubmission", captured[:target_type]
        assert_equal claim.id.to_s, captured[:target_id]
        assert_equal "CREATE", captured[:activity]
        assert captured[:entities].is_a?(Array)
        assert captured[:entities].any?
      end
    end
  end

  test "nil on_provenance does not block authorization" do
    Corvid.configure { |c| c.on_provenance = nil }

    with_tenant(TENANT) do
      referral = authorized_referral_ready_to_authorize!
      assert referral.authorize!
      assert referral.authorized?
    end
  end

  test "on_provenance failure does not roll back authorization" do
    Corvid.configure do |c|
      c.on_provenance = ->(**_attrs) { raise StandardError, "provenance store down" }
    end

    with_tenant(TENANT) do
      referral = authorized_referral_ready_to_authorize!
      logged = []
      Rails.logger.stub(:error, ->(msg) { logged << msg }) do
        assert referral.authorize!
      end
      assert referral.authorized?
      assert logged.any? { |m| m.to_s.include?("Provenance hook failed") },
        "expected provenance failure to be logged, got #{logged.inspect}"
    end
  end

  test "on_provenance database failure does not roll back claim submit!" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at("fac_a", "REF-PROV-SUBMIT-DB")
        authorize_referral!(referral)
        claim = build_claim(
          facility: "fac_a",
          referral_identifier: "REF-PROV-SUBMIT-DB",
          patient: referral.case.patient_identifier,
          service_date: Date.new(2025, 6, 10)
        )
        claim.save!
        Corvid.configure { |c| c.on_provenance = db_failing_provenance_hook }

        claim.submit!
        assert_equal "submitted", claim.reload.status
        assert claim.claim_identifier.present?
      end
    end
  end

  test "on_provenance database failure does not roll back mark_submitted!" do
    with_tenant(TENANT) do
      travel_to Time.zone.parse("2025-06-15 12:00:00 UTC") do
        referral = referral_at("fac_a", "REF-PROV-MARK-DB")
        authorize_referral!(referral)
        claim = build_claim(
          facility: "fac_a",
          referral_identifier: "REF-PROV-MARK-DB",
          patient: referral.case.patient_identifier,
          service_date: Date.new(2025, 6, 10)
        )
        claim.save!
        Corvid.configure { |c| c.on_provenance = db_failing_provenance_hook }

        claim.mark_submitted!(claim_identifier: "CLM-PROV-DB-1")
        claim.reload
        assert_equal "submitted", claim.status
        assert_equal "CLM-PROV-DB-1", claim.claim_identifier
      end
    end
  end

  test "authorize! does not sync authorized CHS status when outer transaction rolls back" do
    updates = []
    Corvid.configure { |c| c.on_provenance = nil }

    with_tenant(TENANT) do
      referral = authorized_referral_ready_to_authorize!
      Corvid.adapter.define_singleton_method(:update_referral) do |identifier, params|
        updates << [ identifier, params.dup ]
        true
      end

      ActiveRecord::Base.transaction do
        assert referral.authorize!
        raise ActiveRecord::Rollback
      end

      refute referral.reload.authorized?
      refute updates.any? { |(_, params)| params[:chs_approval_status] == "A" },
        "expected EHR sync only after commit, got #{updates.inspect}"
    end
  end

  private

  def db_failing_provenance_hook
    ->(**_attrs) { ActiveRecord::Base.connection.execute("SELECT 1/0") }
  end

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: PATIENT,
      facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: identifier,
      facility_identifier: facility
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

  def authorized_referral_ready_to_authorize!
    referral = referral_at(FACILITY, "REF-PROV-AUTH")
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
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.complete_priority_assignment!
    referral.update_column(:status, "priority_assignment")
    referral.reload
  end

  def authorize_referral!(referral)
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
    referral.update!(medical_priority: 2, flagged_for_review: false, estimated_cost: 5_000)
    referral.complete_priority_assignment!
    referral.authorize! if referral.may_authorize?
    referral.reload
  end
end
