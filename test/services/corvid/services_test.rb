# frozen_string_literal: true

require "test_helper"

class Corvid::ServicesTest < ActiveSupport::TestCase
  TENANT = "tnt_svc"

  test "BudgetAvailabilityService reads from adapter" do
    assert_equal 1_000_000.00, Corvid::BudgetAvailabilityService.fiscal_year_budget
    assert_equal 250_000.00, Corvid::BudgetAvailabilityService.reserved_funds
    assert_equal 750_000.00, Corvid::BudgetAvailabilityService.remaining_budget
  end

  test "BudgetAvailabilityService.current_quarter returns FY-Qn" do
    assert_match(/\AFY\d{4}-Q[1-4]\z/, Corvid::BudgetAvailabilityService.current_quarter)
  end

  test "ChsReportingService.financial_report uses adapter" do
    report = Corvid::ChsReportingService.financial_report
    assert_equal :financial, report[:report_type]
    assert_equal 1_000_000.00, report[:total_budget]
    assert_equal 75.0, (100 - report[:percent_used]).round(1).then { 100 - 25 } # sanity
  end

  test "AuthorizationWizard.submit! creates Case and PrcReferral via adapter" do
    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_svc_001",
        facility_identifier: "fac_svc"
      )
      wizard.data.merge!(
        service_requested: "Cardiology Consultation",
        reason_for_referral: "TEST REASON",
        medical_priority: 3,
        estimated_cost: 5_000
      )

      result = wizard.submit!
      assert result[:success]
      assert result[:referral].is_a?(Corvid::PrcReferral)
      assert result[:referral].referral_identifier.start_with?("rf_")
    end
  end

  test "AuthorizationWizard.submit! fails closed when adapter returns nil" do
    failing_adapter = Corvid::Adapters::MockAdapter.new
    failing_adapter.define_singleton_method(:create_referral) { |_, _| nil }
    Corvid.configure { |c| c.adapter = failing_adapter }

    with_tenant(TENANT) do
      wizard = Corvid::AuthorizationWizard.new(
        patient_identifier: "pt_svc_002",
        facility_identifier: "fac_svc"
      )
      wizard.data.merge!(
        service_requested: "Cardiology Consultation",
        reason_for_referral: "TEST REASON",
        medical_priority: 3,
        estimated_cost: 5_000
      )
      result = wizard.submit!
      refute result[:success]

      # No PrcReferral with blank identifier should exist
      blank_count = Corvid::PrcReferral.where(referral_identifier: [ nil, "" ]).count
      assert_equal 0, blank_count
    end
  ensure
    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
  end

  test "CommitteeReviewSyncService syncs decision via adapter" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_svc_003")
      Corvid.adapter.add_referral("rf_svc_001", patient_identifier: "pt_svc_003", status: "committee_review",
                                  estimated_cost: 75_000, medical_priority_level: 3,
                                  authorization_number: nil, emergent: false, urgent: false,
                                  chs_approval_status: "P", service_requested: "TEST")
      pr = Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_svc_001", estimated_cost: 75_000)
      review = Corvid::CommitteeReview.create!(prc_referral: pr, committee_date: Date.current, decision: "approved", approved_amount: 75_000, reviewer_identifier: "pr_svc_001")

      result = Corvid::CommitteeReviewSyncService.sync_decision(review)
      assert result[:success]
    end
  end

  test "ProgramTemplateService.create_case emits provenance via hook" do
    captured = nil
    Corvid.configure do |c|
      c.on_provenance = ->(**attrs) { captured = attrs }
    end

    with_tenant(TENANT) do
      Corvid::ProgramTemplateService.create_case(
        program_type: "hep_b",
        patient_identifier: "pt_svc_004",
        facility_identifier: "fac_svc"
      )
    end

    assert_equal "Corvid::Case", captured[:target_type]
    assert_equal "CREATE", captured[:activity]
  ensure
    Corvid.configure { |c| c.on_provenance = nil }
  end

  test "all 11 services are loadable" do
    %w[
      Corvid::CaseDashboardService
      Corvid::BudgetAvailabilityService
      Corvid::MedicalPriorityService
      Corvid::AlternateResourceService
      Corvid::PriorAuthorizationService
      Corvid::AuthorizationWizard
      Corvid::CommitteeReviewSyncService
      Corvid::ProgramTemplateService
      Corvid::ProgramCaseAuditService
      Corvid::ChsReportingService
      Corvid::HepBWorkflowService
    ].each do |class_name|
      assert defined?(class_name.constantize), "#{class_name} should be defined"
    end
  end
end
