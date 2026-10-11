# frozen_string_literal: true

module Corvid
  # One row per IndianHealthEligibilityService inquiry. A query log, not a
  # determination the engine made. See ADR 0008.
  #
  # asserted_at is text so a replay can return the provider's original
  # instant. timestamp(6) drops sub-microsecond precision.
  class IndianHealthEligibilityInquiry < ::ActiveRecord::Base
    self.table_name = "corvid_indian_health_eligibility_inquiries"

    class ExactTimestamp < ActiveRecord::Type::Value
      def type
        :string
      end

      def cast(value)
        return if value.nil?
        return value if value.acts_like?(:time)

        parsed = Time.iso8601(value.to_s)
        fraction = value.to_s[/\.(\d+)/, 1]
        nsec = fraction ? fraction.ljust(9, "0")[0, 9].to_i : parsed.nsec
        Time.zone.at(parsed.to_i, nsec, :nsec)
      end

      def serialize(value)
        return if value.nil?

        cast(value).iso8601(9)
      end
    end

    attribute :asserted_at, ExactTimestamp.new

    include TenantScoped

    ANSWERS = %w[eligible not_eligible unknown unavailable refused].freeze

    validates :requester_identifier, :agreement_reference, :person_identifier, :message_id, presence: true
    validates :answer, inclusion: { in: ANSWERS }
    validates :replayed, inclusion: { in: [ true, false ] }
  end
end
