# frozen_string_literal: true

module Corvid
  # Per-call usage record for CMS-0057-F API metrics reporting.
  #
  # Not an audit log — we don't store request/response bodies here (see #56
  # for that). This table exists purely to support the public metrics
  # payers must publish annually: unique patients, unique apps, total calls,
  # calls by endpoint.
  #
  # All columns are low-cardinality or opaque identifiers — no PHI at rest.
  class ApiCallLog < ::ActiveRecord::Base
    self.table_name = "corvid_api_call_logs"

    include TenantScoped

    # Mirrors the migration's check constraint.
    API_NAMES = %w[pas patient_access provider_access payer_to_payer].freeze

    validates :api_name, presence: true, inclusion: { in: API_NAMES }
    validates :endpoint, presence: true
    validates :called_at, presence: true

    scope :for_api, ->(name) { where(api_name: name) }
    scope :in_year, ->(year) {
      start_of = Time.zone.local(year, 1, 1)
      end_of = Time.zone.local(year + 1, 1, 1)
      where(called_at: start_of...end_of)
    }
  end
end
