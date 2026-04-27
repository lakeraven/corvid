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
end
