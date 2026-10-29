# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

# Load the dummy app (engine test host), not cucumber/rails which
# expects config/environment at project root.
require_relative "../../test/dummy/config/environment"
require "active_support/testing/time_helpers"
require "minitest/assertions"
require_relative "alternate_resource_exhaustion_helper"
require_relative "referral_fulfilment_helper"

World(Minitest::Assertions)
World(ActiveSupport::Testing::TimeHelpers)

def assertions
  @assertions ||= 0
end

def assertions=(value)
  @assertions = value
end

# Reset tenant context and adapter between scenarios, and clean up after
# the suite so the shared test DB is left empty for subsequent rake test
# runs (cucumber scenarios are not wrapped in transactions).
def clean_corvid_tables!
  # Order matters due to foreign keys.
  Corvid::FmapDetermination.unscoped.delete_all
  Corvid::FacilityAuthority.unscoped.delete_all
  Corvid::FmapRule.unscoped.delete_all
  Corvid::FeeScheduleEntry.unscoped.delete_all
  Corvid::IppsDrgWeight.unscoped.delete_all
  Corvid::IppsHospitalRate.unscoped.delete_all
  Corvid::OppsApcWeight.unscoped.delete_all
  Corvid::OppsConversionFactor.unscoped.delete_all
  Corvid::ZipLocality.unscoped.delete_all
  if Corvid.const_defined?(:ZipCbsaCrosswalk, false)
    Corvid::ZipCbsaCrosswalk.unscoped.delete_all
  end
  Corvid::LocalityLookup.clear_cache!
  Corvid::ApiCallLog.unscoped.delete_all
  Corvid::Payment.unscoped.delete_all
  Corvid::ClaimSubmission.unscoped.delete_all
  Corvid::BillingTransaction.unscoped.delete_all
  Corvid::EligibilityChecklist.unscoped.delete_all
  Corvid::Determination.unscoped.delete_all
  Corvid::PrcEligibilityDecision.unscoped.delete_all
  Corvid::AlternateResourceCheck.unscoped.delete_all
  Corvid::CommitteeReview.unscoped.delete_all
  Corvid::ReferralFulfilmentReport.unscoped.delete_all
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

After do
  travel_back
end

Before do
  Corvid::PrcFacilityDictionary.reset!
  Corvid::TenantContext.reset!
  # Replace adapter with fresh instance to discard any singleton methods
  # added by scenarios (e.g., mocking submit_claim to raise).
  Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
  # ProgramRegistry is process-global; reset to defaults so scenario-level
  # host registrations (e.g. "access_bh") don't leak into later scenarios.
  Corvid::ProgramRegistry.reset!
  clean_corvid_tables!
end

# Final sweep so a subsequent `rake test` (against the same test DB)
# doesn't observe residue from the last scenario. Runs once at the end
# of the suite, not per-scenario — the Before hook already guarantees
# intra-suite isolation, so doubling up in an After would just double
# the per-scenario DELETE cost.
AfterAll do
  clean_corvid_tables!
end
