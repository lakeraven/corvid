# frozen_string_literal: true

require "test_helper"

class Corvid::PriorAuthorizationServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_pa_test"

  test "service class exists and is callable" do
    with_tenant(TENANT) do
      assert defined?(Corvid::PriorAuthorizationService)
    end
  end

  # -- Emergency authorization (72-hour notification window) ------------------

  test "emergency service request requires notification within 72 hours" do
    with_tenant(TENANT) do
      sr = build_service_request(urgency: "EMERGENT", requested_on: Date.current, authorization_required: true)
      result = Corvid::PriorAuthorizationService.check(sr)

      assert_equal :emergency, result.authorization_type
      assert result.notification_deadline.present?
      assert_equal Date.current + 3.days, result.notification_deadline
      assert_includes result.message, "72-hour notification"
    end
  end

  test "emergency service request within 72 hours is compliant" do
    with_tenant(TENANT) do
      sr = build_service_request(urgency: "EMERGENT", requested_on: Date.current - 1.day)
      result = Corvid::PriorAuthorizationService.check(sr)

      assert result.compliant?
      assert result.within_notification_window?
    end
  end

  test "emergency service request beyond 72 hours requires retroactive authorization" do
    with_tenant(TENANT) do
      sr = build_service_request(urgency: "EMERGENT", requested_on: Date.current - 5.days)
      result = Corvid::PriorAuthorizationService.check(sr)

      refute result.within_notification_window?
      assert result.requires_retroactive_authorization?
      assert_includes result.message, "retroactive"
    end
  end

  # -- Non-emergency prior authorization --------------------------------------

  test "non-emergency service request requires prior authorization before service" do
    with_tenant(TENANT) do
      sr = build_service_request(urgency: "ROUTINE", authorization_required: true, authorization_reason: "Specialty not available")
      result = Corvid::PriorAuthorizationService.check(sr)

      assert_equal :prior, result.authorization_type
      assert result.requires_prior_authorization?
      assert_includes result.message, "Prior authorization required before service"
    end
  end

  test "urgent non-emergency service request requires prior authorization" do
    with_tenant(TENANT) do
      sr = build_service_request(urgency: "URGENT", authorization_required: true, authorization_reason: "Urgent referral")
      result = Corvid::PriorAuthorizationService.check(sr)

      assert result.requires_prior_authorization?
      assert_equal :prior, result.authorization_type
    end
  end

  test "service request without authorization flag does not require authorization" do
    with_tenant(TENANT) do
      sr = build_service_request(urgency: "ROUTINE", authorization_required: false)
      result = Corvid::PriorAuthorizationService.check(sr)

      refute result.requires_prior_authorization?
      assert result.compliant?
    end
  end

  # -- High-cost committee review ---------------------------------------------

  test "high-cost service request requires committee review" do
    with_tenant(TENANT) do
      sr = build_service_request(estimated_cost: 50_000, requires_committee_review: true)
      result = Corvid::PriorAuthorizationService.check(sr)

      assert result.requires_committee_review?
      assert_includes result.message, "committee review"
    end
  end

  test "service request above cost threshold triggers committee review" do
    with_tenant(TENANT) do
      sr = build_service_request(estimated_cost: 100_000)
      result = Corvid::PriorAuthorizationService.check(sr)

      assert result.requires_committee_review?
      assert_includes result.authorization_reason, "cost threshold"
    end
  end

  test "blank authorization reason above cost threshold uses cost threshold exceeded reason" do
    with_tenant(TENANT) do
      sr = build_service_request(
        urgency: "ROUTINE",
        authorization_required: true,
        authorization_reason: "",
        estimated_cost: 100_000
      )
      result = Corvid::PriorAuthorizationService.check(sr)

      assert_includes result.authorization_reason, "cost threshold exceeded"
    end
  end

  test "whitespace authorization reason above cost threshold uses cost threshold exceeded reason" do
    with_tenant(TENANT) do
      sr = build_service_request(
        urgency: "ROUTINE",
        authorization_required: true,
        authorization_reason: "   ",
        estimated_cost: 100_000
      )
      result = Corvid::PriorAuthorizationService.check(sr)

      assert_includes result.authorization_reason, "cost threshold exceeded"
    end
  end

  test "service request below cost threshold does not require committee review" do
    with_tenant(TENANT) do
      sr = build_service_request(estimated_cost: 5_000, requires_committee_review: false)
      result = Corvid::PriorAuthorizationService.check(sr)

      refute result.requires_committee_review?
    end
  end

  # -- Authorization reason documentation ------------------------------------

  test "missing authorization reason when required fails compliance" do
    with_tenant(TENANT) do
      sr = build_service_request(authorization_required: true, authorization_reason: nil)
      result = Corvid::PriorAuthorizationService.check(sr)

      refute result.compliant?
      assert_includes result.message, "authorization reason required"
    end
  end

  # -- Case manager assignment -----------------------------------------------

  test "complex service request requires case manager assignment" do
    with_tenant(TENANT) do
      sr = build_service_request(estimated_cost: 75_000, requires_committee_review: true, case_manager_ien: nil)
      result = Corvid::PriorAuthorizationService.check(sr)

      assert result.requires_case_manager?
      assert_includes result.message, "case manager"
    end
  end

  test "service request with assigned case manager is compliant" do
    with_tenant(TENANT) do
      sr = build_service_request(estimated_cost: 75_000, requires_committee_review: true, case_manager_ien: 555, authorization_required: true, authorization_reason: "Specialized cardiac surgery")
      result = Corvid::PriorAuthorizationService.check(sr)

      assert result.has_case_manager?
    end
  end

  # -- Complete workflows -----------------------------------------------------

  test "complete authorization workflow for routine service request" do
    with_tenant(TENANT) do
      sr = build_service_request(
        urgency: "ROUTINE", authorization_required: true,
        authorization_reason: "Specialty not available", estimated_cost: 3_000
      )
      result = Corvid::PriorAuthorizationService.check(sr)

      assert_equal :prior, result.authorization_type
      assert result.requires_prior_authorization?
      refute result.requires_committee_review?
    end
  end

  test "complete authorization workflow for expensive urgent service request" do
    with_tenant(TENANT) do
      sr = build_service_request(
        urgency: "URGENT", authorization_required: true,
        authorization_reason: "Specialized cardiac surgery",
        estimated_cost: 150_000, requires_committee_review: true,
        case_manager_ien: 789
      )
      result = Corvid::PriorAuthorizationService.check(sr)

      assert_equal :prior, result.authorization_type
      assert result.requires_prior_authorization?
      assert result.requires_committee_review?
      assert result.has_case_manager?
      assert result.compliant?
    end
  end

  test "emergency service request converts to retroactive after 72 hours" do
    with_tenant(TENANT) do
      sr = build_service_request(urgency: "EMERGENT", requested_on: Date.current - 10.days, authorization_required: true)
      result = Corvid::PriorAuthorizationService.check(sr)

      refute result.within_notification_window?
      assert result.requires_retroactive_authorization?
    end
  end

  # -- PRC referral auto-authorization (42 CFR 136.61 exhaustion) ------------

  test "auto_authorizable? false when referral has no alternate resource checks" do
    with_tenant(TENANT) do
      referral = create_referral_without_committee

      refute Corvid::PriorAuthorizationService.auto_authorizable?(referral)
    end
  end

  test "auto_authorizable? false when only a partial set of alternate resources is unavailable" do
    with_tenant(TENANT) do
      referral = create_referral_without_committee
      %w[medicare_a medicaid private_insurance charity_care].each do |type|
        Corvid::AlternateResourceCheck.create!(
          prc_referral: referral, resource_type: type, status: "not_enrolled"
        )
      end

      refute Corvid::PriorAuthorizationService.auto_authorizable?(referral)
    end
  end

  test "auto_authorizable? true when all twelve alternate resources are unavailable and committee not required" do
    with_tenant(TENANT) do
      referral = create_referral_without_committee
      create_all_twelve_unavailable_checks(
        referral,
        "medicare_a" => "not_enrolled",
        "medicaid" => "denied",
        "private_insurance" => "exhausted"
      )

      assert Corvid::PriorAuthorizationService.auto_authorizable?(referral)
    end
  end

  test "auto_authorizable? false when committee review is required even if all resources exhausted" do
    with_tenant(TENANT) do
      referral = create_referral_without_committee(estimated_cost: 50_000)
      create_all_twelve_unavailable_checks(referral)

      refute Corvid::PriorAuthorizationService.auto_authorizable?(referral)
    end
  end

  private

  def build_service_request(attrs = {})
    OpenStruct.new({
      urgency: "ROUTINE",
      requested_on: Date.current,
      authorization_required: false,
      authorization_reason: nil,
      estimated_cost: 0,
      requires_committee_review: false,
      case_manager_ien: nil
    }.merge(attrs))
  end

  def create_referral_without_committee(estimated_cost: 1_000, medical_priority: 2, flagged_for_review: false)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_pa_test_001",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
    Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "ref_#{SecureRandom.hex(4)}",
      facility_identifier: "fac_test",
      estimated_cost: estimated_cost,
      medical_priority: medical_priority,
      flagged_for_review: flagged_for_review
    )
  end

  def create_all_twelve_unavailable_checks(referral, status_overrides = {})
    Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
      status = status_overrides.fetch(type, "not_enrolled")
      check = Corvid::AlternateResourceCheck.create!(
        prc_referral: referral,
        resource_type: type,
        status: status
      )
      stamp_alternate_resource_check_current!(check) unless %w[not_checked checking].include?(status)
    end
  end
end
