# frozen_string_literal: true

module Corvid
  # A single PRC obligation imported from an RPMS PRC export file.
  # Mirror of the O-record fields plus source-file provenance.
  class PrcObligation < ::ActiveRecord::Base
    self.table_name = "corvid_prc_obligations"

    include TenantScoped

    has_many :prc_payments,
             dependent: :destroy,
             class_name: "Corvid::PrcPayment"
    has_many :prc_overpayment_analyses,
             dependent: :destroy,
             class_name: "Corvid::PrcOverpaymentAnalysis"

    validates :facility_identifier, presence: true
    validates :obligation_id, presence: true
    validates :imported_at, presence: true

    scope :for_facility, ->(code) { where(facility_identifier: code) }
    scope :for_vendor, ->(vendor_id) { where(vendor_id: vendor_id) }
    scope :for_year, ->(year) { where(fiscal_year: year) }

    # Most recent analysis (if any). Reports usually display the latest;
    # history is preserved by the analyses table.
    def latest_analysis
      prc_overpayment_analyses.order(analyzed_at: :desc).first
    end
  end
end
