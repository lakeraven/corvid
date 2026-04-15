# frozen_string_literal: true

# Shared helper: ensures one checklist per referral, update in place, reload.
module ChecklistHelper
  def checklist_for(referral)
    referral.reload
    checklist = referral.eligibility_checklist ||
      Corvid::EligibilityChecklist.create!(
        prc_referral: referral,
        tenant_identifier: referral.tenant_identifier,
        facility_identifier: referral.facility_identifier
      )
    yield checklist if block_given?
    referral.reload
    checklist
  end
end

World(ChecklistHelper)
