# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

# Load the dummy app (engine test host), not cucumber/rails which
# expects config/environment at project root.
require_relative "../../test/dummy/config/environment"
require "minitest/assertions"

World(Minitest::Assertions)

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
  Corvid::ApiCallLog.unscoped.delete_all
  Corvid::Payment.unscoped.delete_all
  Corvid::ClaimSubmission.unscoped.delete_all
  Corvid::BillingTransaction.unscoped.delete_all
  Corvid::EligibilityChecklist.unscoped.delete_all
  Corvid::Determination.unscoped.delete_all
  Corvid::AlternateResourceCheck.unscoped.delete_all
  Corvid::CommitteeReview.unscoped.delete_all
  Corvid::Task.unscoped.delete_all
  Corvid::PrcReferral.unscoped.delete_all
  Corvid::Case.unscoped.delete_all
  Corvid::CareTeamMember.unscoped.delete_all
  Corvid::CareTeam.unscoped.delete_all
end

Before do
  Corvid::TenantContext.reset!
  # Replace adapter with fresh instance to discard any singleton methods
  # added by scenarios (e.g., mocking submit_claim to raise).
  Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
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
