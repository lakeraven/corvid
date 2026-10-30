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
    # Validation and submission share one edit list (`rejection_edits`).
    # Validating does not record a submission; only `submit_claim` does.
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

      # Front-end edits for this claim, from the same list `submit_claim`
      # will apply. Does not append to `submitted`. `raw_reference` stays
      # nil: this client has no transport handle to return.
      def validate_claim(claim)
        raise ArgumentError, "validate_claim expects a Claim" unless claim.is_a?(Claim)

        edits = rejection_edits(claim)
        ClaimValidation.new(
          claim_identifier: claim.identifier,
          valid: edits.empty?,
          edits: edits,
          raw_reference: nil
        )
      end

      def submit_claim(claim)
        edits = rejection_edits(claim)
        @submitted << claim
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

      # One edit list for `validate_claim` and `submit_claim`, so the two
      # cannot disagree about the same claim.
      #
      # A claim listed under `rejections` — the key is present, whatever its
      # value — must yield at least one edit, and every canned edit must
      # have a non-blank code and a non-blank description. Otherwise this
      # raises ArgumentError ("canned rejection has no usable edit"), and
      # that message does not include the claim identifier. A missing
      # `code` or `description` key still fails closed through `Hash#fetch`.
      # A claim that is not listed keeps the front-door rule: a blank
      # billing provider NPI is the missing-NPI edit, and any other claim
      # is clean.
      def rejection_edits(claim)
        identifier = claim.identifier.to_s
        return front_door_edits(claim) unless rejections.key?(identifier)

        listed_rejection_edits(rejections.fetch(identifier))
      end

      def front_door_edits(claim)
        return [ MISSING_BILLING_NPI_EDIT ] if claim.billing_provider_npi.to_s.strip.empty?

        []
      end

      def listed_rejection_edits(entry)
        raw = entry.is_a?(Hash) ? entry["edits"] : nil
        raise_unusable_canned_rejection! if !raw.is_a?(Array) || raw.empty?

        raw.map { |edit| canned_edit(edit) }
      end

      def canned_edit(edit)
        raise_unusable_canned_rejection! unless edit.is_a?(Hash)

        code = edit.fetch("code")
        description = edit.fetch("description")
        if code.to_s.strip.empty? || description.to_s.strip.empty?
          raise_unusable_canned_rejection!
        end

        AcknowledgmentEdit.new(
          code: code,
          description: description,
          element: edit["element"],
          level: edit.fetch("level", "claim")
        )
      end

      def raise_unusable_canned_rejection!
        raise ArgumentError, "canned rejection has no usable edit"
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
