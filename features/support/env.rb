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

# Reset tenant context and adapter between scenarios
Before do
  Corvid::TenantContext.reset!
  Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)

  # Clean corvid tables (order matters due to foreign keys)
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
