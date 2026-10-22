# frozen_string_literal: true

module Corvid
  # One row per IndianHealthEligibilityService inquiry. A query log of the
  # answer the provider gave, not a determination the engine made. See ADR 0009.
  #
  # asserted_at is datetime(6): the provider's time, replayed as the same instant.
  class IndianHealthEligibilityInquiry < ::ActiveRecord::Base
    self.table_name = "corvid_indian_health_eligibility_inquiries"

    include TenantScoped

    ANSWERS = %w[eligible not_eligible unknown unavailable refused].freeze

    validates :requester_identifier, :agreement_reference, :person_identifier, :message_id, presence: true
    validates :answer, inclusion: { in: ANSWERS }
    validates :replayed, inclusion: { in: [ true, false ] }
  end
end
