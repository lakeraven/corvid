# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"

# FK-correct table cleanup. Mirrors features/support/env.rb so minitest
# and cucumber share the same deletion order.
def clean_corvid_tables!
  Corvid::FeeSchedule.unscoped.delete_all
  Corvid::FeeScheduleEntry.unscoped.delete_all
  Corvid::IppsDrgWeight.unscoped.delete_all
  Corvid::IppsHospitalRate.unscoped.delete_all
  Corvid::OppsApcWeight.unscoped.delete_all
  Corvid::OppsConversionFactor.unscoped.delete_all
  Corvid::ZipLocality.unscoped.delete_all
  Corvid::LocalityLookup.clear_cache!
  Corvid::ApiCallLog.unscoped.delete_all
  Corvid::Payment.unscoped.delete_all
  Corvid::ClaimSubmission.unscoped.delete_all
  Corvid::BillingTransaction.unscoped.delete_all
  Corvid::EligibilityChecklist.unscoped.delete_all
  Corvid::Determination.unscoped.delete_all
  Corvid::AlternateResourceCheck.unscoped.delete_all
  Corvid::CommitteeReview.unscoped.delete_all
  Corvid::PrcOverpaymentAnalysis.unscoped.delete_all
  Corvid::PrcPayment.unscoped.delete_all
  Corvid::PrcObligation.unscoped.delete_all
  Corvid::Task.unscoped.delete_all
  Corvid::PrcReferral.unscoped.delete_all
  Corvid::CaseProgram.unscoped.delete_all
  Corvid::Case.unscoped.delete_all
  Corvid::CareTeamMember.unscoped.delete_all
  Corvid::CareTeam.unscoped.delete_all
end

# Reset state between tests
module ActiveSupport
  class TestCase
    setup do
      Corvid::TenantContext.reset!
      Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
      clean_corvid_tables!
    end

    teardown do
      Corvid::TenantContext.reset!
    end

    private

    def with_tenant(identifier, &block)
      Corvid::TenantContext.with_tenant(identifier, &block)
    end
  end
end
