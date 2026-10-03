require "test_helper"
require "yaml"

module Corvid
  class PhiSchemaGuardTest < ActiveSupport::TestCase
    # Engine root, NOT Rails.root. In an engine's suite Rails.root is the dummy
    # app (test/dummy), so Rails.root.join("docs") silently resolves to a path
    # that does not exist, load_exceptions returns empty, and every exception
    # fails as though it were new. Found by running it; static reading missed it.
    EXCEPTIONS_FILE = Corvid::Engine.root.join("docs", "phi-column-exceptions.yml")

    # Tables that hold public CMS reference data, not patient-linked.
    REFERENCE_TABLES = %w[
      corvid_fee_schedules
      corvid_fee_schedule_entries
      corvid_cms_fee_schedule_releases
      corvid_ipps
      corvid_ipps_rates
      corvid_opps
      corvid_opps_rates
      corvid_asc
      corvid_asc_rates
      corvid_cah
      corvid_cah_facilities
      corvid_npi_ccn
      corvid_npi_ccn_crosswalks
      corvid_zip_localities
    ].freeze

    # These are hardcoded as failures in this test per instructions.
    HARD_FAILURES = [
      [ "corvid_cases", "patient_name_cached" ],
      [ "corvid_cases", "patient_dob_cached" ]
    ].freeze

    def test_no_phi_in_schema
      exceptions = load_exceptions
      violations = []
      tables_scanned = 0
      columns_scanned = 0

      ActiveRecord::Base.connection.tables.grep(/^corvid_/).each do |table_name|
        tables_scanned += 1
        is_reference_table = REFERENCE_TABLES.any? { |rt| table_name == rt || table_name.start_with?(rt) }

        ActiveRecord::Base.connection.columns(table_name).each do |column|
          columns_scanned += 1
          col_name = column.name

          # Allowed by ADR 0001 / 0003
          next if col_name.end_with?("_token", "_identifier")
          next if %w[tenant_identifier facility_identifier].include?(col_name)
          next if %w[status lifecycle_status priority program_type current_activity closure_reason decision enrollment_status resource_type role].include?(col_name)
          next if col_name == "currency_iso" || col_name.end_with?("_cents") || col_name == "amount"
          next if col_name.end_with?("_at") # timestamps

          # Reference tables are exempt from the PHI pattern scan
          next if is_reference_table

          reason = detect_phi_pattern(col_name, column.type)

          if reason
            if exceptions[table_name]&.include?(col_name) && !HARD_FAILURES.include?([ table_name, col_name ])
              # Known exception, ignore
            else
              violations << { table: table_name, column: col_name, reason: reason }
            end
          end
        end
      end

      if violations.any?
        grouped = violations.group_by { |v| v[:table] }
        msg = "Found plaintext PHI columns in the schema:\n\n"
        grouped.each do |table, cols|
          msg += "#{table}:\n"
          cols.each do |c|
            msg += "  - #{c[:column]} (#{c[:reason]})\n"
          end
        end
        msg += "\nIf these are known and accepted for now, add them to docs/phi-column-exceptions.yml"
        flunk msg
      end

      # A scan that examined nothing also finds no violations. Without these,
      # this test passes with ZERO assertions — and would keep passing if the
      # connection returned no tables, if the /^corvid_/ grep stopped matching,
      # or if someone narrowed the loop. Assert the scan did work, not merely
      # that it was quiet.
      assert_operator tables_scanned, :>=, 20,
        "scanned only #{tables_scanned} corvid_* tables — the scan is broken, not the schema clean"
      assert_operator columns_scanned, :>=, 150,
        "scanned only #{columns_scanned} columns — the scan is broken, not the schema clean"
    end

    private

    def load_exceptions
      return {} unless File.exist?(EXCEPTIONS_FILE)

      data = YAML.load_file(EXCEPTIONS_FILE) || []

      # Transform to hash of table => [columns]
      exceptions = Hash.new { |h, k| h[k] = [] }
      data.each do |entry|
        exceptions[entry["table"]] << entry["column"]
      end
      exceptions
    end

    def detect_phi_pattern(name, type)
      if name.match?(/name/)
        "(A) Names"
      elsif name.match?(/dob|birth/)
        "(C) All elements of dates directly related to an individual"
      elsif name.match?(/ssn/)
        "(G) Social security numbers"
      elsif name.match?(/mrn|dfn/)
        "(H) Medical record numbers"
      elsif name.match?(/address/)
        "(B) Geographic subdivisions smaller than a state"
      elsif name.match?(/phone/)
        "(D) Telephone numbers"
      elsif name.match?(/email/)
        "(F) Electronic mail addresses"
      elsif name.match?(/policy/)
        "(I) Health plan beneficiary numbers"
      elsif name.match?(/group_number/)
        "(I) Health plan beneficiary numbers"
      elsif name.match?(/authorization_number/)
        "(J) Account numbers"
      elsif name.match?(/check_number/)
        "(J) Account numbers"
      elsif type == :date || type == :datetime
        "(C) All elements of dates directly related to an individual (bare date/datetime)"
      else
        nil
      end
    end
  end
end
