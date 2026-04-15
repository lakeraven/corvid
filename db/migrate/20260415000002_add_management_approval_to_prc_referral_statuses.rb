# frozen_string_literal: true

class AddManagementApprovalToPrcReferralStatuses < ActiveRecord::Migration[8.1]
  PRC_STATUSES = %w[
    draft submitted eligibility_review management_approval alternate_resource_review
    priority_assignment committee_review exception_review
    authorized denied deferred cancelled
  ].freeze

  def up
    remove_check_constraint :corvid_prc_referrals, name: "corvid_prc_referrals_status_check"
    add_check_constraint :corvid_prc_referrals,
                         "status IN (#{PRC_STATUSES.map { |s| "'#{s}'" }.join(',')})",
                         name: "corvid_prc_referrals_status_check"
  end

  def down
    old_statuses = PRC_STATUSES - %w[management_approval]
    remove_check_constraint :corvid_prc_referrals, name: "corvid_prc_referrals_status_check"
    add_check_constraint :corvid_prc_referrals,
                         "status IN (#{old_statuses.map { |s| "'#{s}'" }.join(',')})",
                         name: "corvid_prc_referrals_status_check"
  end
end
