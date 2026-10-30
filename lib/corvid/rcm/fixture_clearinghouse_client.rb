# frozen_string_literal: true

require "bigdecimal"
require "date"
require "yaml"

require_relative "clearinghouse_client"
require_relative "edi_835_reader"

module Corvid
  module Rcm
    # A `ClearinghouseClient` backed by synthetic 835 files, a canned
    # acknowledgment table, and canned 277 claim-status answers. No network,
    # no credentials, no clock skew — the same inputs always produce the same
    # outputs, so posting, routing, and status checks can be exercised against
    # real X12 shapes without a payer connection.
    #
    # The 835 fixtures are parsed, not hand-built as hashes: if the reader
    # mis-parses a segment the tests fail, which is the point.
    class FixtureClearinghouseClient < ClearinghouseClient
      FIXTURE_DIR = File.expand_path("fixtures/835", __dir__)
      ACKNOWLEDGMENT_TABLE = File.expand_path("data/clearinghouse_acknowledgments.yml", __dir__)
      CLAIM_STATUS_TABLE = File.expand_path("data/clearinghouse_claim_statuses.yml", __dir__)

      # Decimal strings with two fractional digits. A YAML float would already
      # have been rounded before we ever saw it, so anything else is refused.
      DECIMAL_AMOUNT = /\A(?:0|[1-9]\d*)\.\d{2}\z/
      ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
      CANNED_STATUS_FIELDS = %w[
        payer_control_number category category_code status_code paid_amount paid_date
      ].freeze

      # Scenarios in a stable order — the order `fetch_remittances` returns.
      SCENARIOS = %w[
        clean_full_pay
        partial_pay_patient_responsibility
        denial_missing_information_co16
        denial_duplicate_co18
        denial_timely_filing_co29
        denial_medical_necessity_co50
        denial_bundled_co97
        denial_authorization_required_co197
        denial_unmapped_reason_code
      ].freeze

      # A front-door edit every clearinghouse runs: no billing provider NPI,
      # no claim. Modelled here so a rejection can be produced from a claim's
      # own content, not only from the canned table.
      MISSING_BILLING_NPI_EDIT = AcknowledgmentEdit.new(
        code: "A7:562",
        description: "Entity's National Provider Identifier (NPI) — the billing provider NPI is missing from the claim.",
        element: "NM1*85 billing provider",
        level: "claim"
      )

      def initialize(scenarios: SCENARIOS, fixture_dir: FIXTURE_DIR,
                     acknowledgment_table: ACKNOWLEDGMENT_TABLE,
                     claim_statuses: CLAIM_STATUS_TABLE, clock: -> { Time.now.utc })
        @scenarios = Array(scenarios)
        @fixture_dir = fixture_dir
        @clock = clock
        @table = YAML.safe_load_file(acknowledgment_table)
        @claim_statuses = load_claim_statuses(claim_statuses)
        @submitted = []
      end

      # Every claim handed to `submit_claim`, in order. Phase 0's stand-in for
      # the submission event log (wave 2, with #507).
      attr_reader :submitted

      def submit_claim(claim)
        @submitted << claim
        edits = rejection_edits(claim)
        return acknowledgment(claim, :accepted, transaction_set: default_transaction_set) if edits.empty?

        acknowledgment(claim, :rejected,
                       transaction_set: transaction_set_for(claim),
                       edits: edits)
      end

      # An undated remittance is kept rather than filtered out: dropping one
      # because its date is unknown would be dropping money silently.
      def fetch_remittances(date_range: nil)
        @scenarios.map { |scenario| remittance(scenario) }.select do |rem|
          date_range.nil? || rem.payment_date.nil? || date_range.cover?(rem.payment_date)
        end
      end

      # A canned 277 when the identifier is on file. Unknown identifiers are
      # :not_found — there is no STC category code, because the claim is not
      # on file. `as_of` is the injected clock. `raw_reference` is always nil.
      def check_claim_status(claim_identifier)
        reject_bad_identifier!(claim_identifier)
        canned = @claim_statuses[claim_identifier]
        return not_found_status(claim_identifier) if canned.nil?

        canned.with(as_of: @clock.call, raw_reference: nil)
      end

      # One scenario by name, e.g. `client.remittance("denial_duplicate_co18")`.
      def remittance(scenario)
        path = fixture_path(scenario)
        raise ArgumentError, "no 835 fixture for scenario #{scenario.inspect}" unless File.exist?(path)

        Edi835Reader.read(path)
      end

      def scenarios
        @scenarios.dup
      end

      private

      def fixture_path(scenario)
        File.join(@fixture_dir, "#{scenario}.835")
      end

      def rejections
        @table.fetch("rejections", {})
      end

      def default_transaction_set
        @table.fetch("default_transaction_set", "277CA")
      end

      def transaction_set_for(claim)
        rejections.dig(claim.identifier.to_s, "transaction_set") || default_transaction_set
      end

      def rejection_edits(claim)
        canned = Array(rejections.dig(claim.identifier.to_s, "edits")).map do |edit|
          AcknowledgmentEdit.new(
            code: edit.fetch("code"),
            description: edit.fetch("description"),
            element: edit["element"],
            level: edit.fetch("level", "claim")
          )
        end
        return canned if canned.any?

        claim.billing_provider_npi.to_s.strip.empty? ? [ MISSING_BILLING_NPI_EDIT ] : []
      end

      def acknowledgment(claim, outcome, transaction_set:, edits: [])
        Acknowledgment.new(
          claim_identifier: claim.identifier,
          trace_number: "ACK-#{claim.identifier}",
          outcome: outcome,
          transaction_set: transaction_set,
          received_at: @clock.call,
          edits: edits
        )
      end

      def reject_bad_identifier!(claim_identifier)
        return if claim_identifier.is_a?(String) && !claim_identifier.strip.empty?

        raise ArgumentError, ClaimStatus::INVALID_CLAIM_IDENTIFIER
      end

      def not_found_status(claim_identifier)
        ClaimStatus.new(
          claim_identifier: claim_identifier,
          category: :not_found,
          category_code: nil,
          as_of: @clock.call,
          raw_reference: nil
        )
      end

      # Building each row runs ClaimStatus's checks, so a category that does
      # not agree with its category code fails here, when the table is loaded.
      def load_claim_statuses(path)
        table = YAML.safe_load_file(path, freeze: true)
        raise ArgumentError, "claim status table must be a mapping" unless table.is_a?(Hash)

        table.to_h { |identifier, row| [ identifier, build_canned_status(identifier, row) ] }.freeze
      end

      def build_canned_status(identifier, row)
        raise ArgumentError, "canned claim status row must be a mapping" unless row.is_a?(Hash)

        unknown = row.keys - CANNED_STATUS_FIELDS
        raise ArgumentError, "canned claim status row has an unknown field" unless unknown.empty?

        ClaimStatus.new(
          claim_identifier: identifier,
          payer_control_number: optional_control_number(row["payer_control_number"]),
          category: category_symbol(row["category"]),
          category_code: required_category_code(row["category_code"]),
          status_code: required_status_code(row["status_code"]),
          paid_amount: parse_paid_amount(row["paid_amount"]),
          paid_date: parse_paid_date(row["paid_date"]),
          raw_reference: nil
        )
      end

      def category_symbol(name)
        found = ClaimStatus::CATEGORIES.find { |category| category.to_s == name }
        raise ArgumentError, ClaimStatus::UNKNOWN_CATEGORY if found.nil?

        found
      end

      def required_category_code(value)
        raise ArgumentError, "category_code must be a String" unless value.is_a?(String)

        value
      end

      def required_status_code(value)
        return value if value.is_a?(String) && !value.strip.empty?

        raise ArgumentError, "status_code must be a non-blank String"
      end

      def optional_control_number(value)
        return nil if value.nil?
        raise ArgumentError, "payer_control_number must be a String" unless value.is_a?(String)
        raise ArgumentError, "payer_control_number must be a non-blank String" if value.strip.empty?

        value
      end

      def parse_paid_amount(value)
        return nil if value.nil?
        raise ArgumentError, "paid_amount must be a decimal string" unless value.is_a?(String) && DECIMAL_AMOUNT.match?(value)

        BigDecimal(value)
      end

      def parse_paid_date(value)
        return nil if value.nil?
        raise ArgumentError, "paid_date must be an ISO-8601 date" unless value.is_a?(String) && ISO_DATE.match?(value)

        Date.strptime(value, "%Y-%m-%d")
      end
    end
  end
end
