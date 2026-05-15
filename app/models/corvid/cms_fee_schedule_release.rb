# frozen_string_literal: true

module Corvid
  # Provenance metadata for a single CMS fee schedule year ingestion.
  # Lets PrcOverpaymentAnalyzer and audit consumers answer "where did this rate
  # come from?" without re-reading source files. One row per ingested year.
  class CmsFeeScheduleRelease < ::ActiveRecord::Base
    self.table_name = "corvid_cms_fee_schedule_releases"

    validates :year, presence: true, uniqueness: true
    validates :cms_release_tag, presence: true
    validates :source_checksum_sha256, presence: true
    validates :parser_version, presence: true
    validates :ingested_at, presence: true
    validates :row_count, numericality: { greater_than_or_equal_to: 0 }
  end
end
