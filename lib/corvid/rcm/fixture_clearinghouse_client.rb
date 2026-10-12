# frozen_string_literal: true

require "yaml"

require_relative "clearinghouse_client"
require_relative "edi_835_reader"

module Corvid
  module Rcm
    # A `ClearinghouseClient` backed by synthetic 835 files and a canned
    # acknowledgment table. No network, no credentials, no clock skew — the
    # same inputs always produce the same outputs, so the posting and routing
    # logic can be tested against real X12 syntax without a payer connection.
    #
    # The 835 fixtures are parsed, not hand-built as hashes: if the reader
    # mis-parses a segment the tests fail, which is the point.
    class FixtureClearinghouseClient < ClearinghouseClient
      FIXTURE_DIR = File.expand_path("fixtures/835", __dir__)
      ACKNOWLEDGMENT_TABLE = File.expand_path("data/clearinghouse_acknowledgments.yml", __dir__)

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
                     acknowledgment_table: ACKNOWLEDGMENT_TABLE, clock: -> { Time.now.utc })
        @scenarios = Array(scenarios)
        @fixture_dir = fixture_dir
        @clock = clock
        @table = YAML.safe_load_file(acknowledgment_table)
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

      def fetch_remittances(since: nil)
        @scenarios.map { |scenario| remittance(scenario) }.select do |rem|
          since.nil? || rem.payment_date.nil? || rem.payment_date >= since
        end
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
    end
  end
end
