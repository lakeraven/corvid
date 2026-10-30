# frozen_string_literal: true

require "yaml"

require_relative "clearinghouse_client"
require_relative "edi_835_reader"
require_relative "edi_271_reader"

module Corvid
  module Rcm
    # A `ClearinghouseClient` backed by synthetic 835 and 271 files and a canned
    # acknowledgment table. No network, no credentials, no clock skew — the
    # same inputs always produce the same outputs, so posting, routing, and
    # eligibility can be tested against real X12 syntax without a payer
    # connection.
    #
    # The fixtures are parsed, not hand-built as hashes: if a reader mis-parses
    # a segment the tests fail, which is the point. Eligibility fixtures are
    # one 271 per member identifier. The identifier is untrusted and is not
    # stripped or normalised: only a raw value matching a single
    # `[A-Za-z0-9_-]` token (`\z`, so a trailing newline fails) is opened,
    # and the resolved path has to stay inside the fixture directory,
    # including after symlink resolution. Anything else — a blank identifier,
    # a token with no fixture, or a file `Edi271Reader` rejects as malformed
    # — is `:undetermined`. Unknown is never a no. `check_eligibility` always
    # returns an `EligibilityResponse` for an `EligibilityInquiry`. Anything
    # else raises ArgumentError with `ClearinghouseClient::INQUIRY_REQUIRED_MESSAGE`,
    # which does not include the argument. The reader itself still raises
    # `Edi271Reader::MalformedError` with a fixed message and `cause: nil`,
    # so a member identifier or the file body cannot ride out on the
    # exception (ADR 0003); this client catches that and answers
    # `:undetermined` with no plans, no errors, and no raw reference.
    class FixtureClearinghouseClient < ClearinghouseClient
      FIXTURE_DIR = File.expand_path("fixtures/835", __dir__)
      ELIGIBILITY_FIXTURE_DIR = File.expand_path("fixtures/271", __dir__)
      ACKNOWLEDGMENT_TABLE = File.expand_path("data/clearinghouse_acknowledgments.yml", __dir__)

      # Member identifiers are path segments. The raw value must match this
      # token (`\z`, so a trailing newline does not pass). It is not stripped
      # or normalised. Dots, slashes, spaces, and anything else that could
      # leave the fixture directory are refused before `File` sees them.
      MEMBER_TOKEN = /\A[A-Za-z0-9_-]+\z/

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
                     acknowledgment_table: ACKNOWLEDGMENT_TABLE, clock: -> { Time.now.utc },
                     eligibility_fixture_dir: ELIGIBILITY_FIXTURE_DIR)
        @scenarios = Array(scenarios)
        @fixture_dir = fixture_dir
        @eligibility_fixture_dir = eligibility_fixture_dir
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

      # One 271 per member identifier. Payer, service date, service type codes,
      # and provider NPI stay on the inquiry — they are what a live 270 would
      # send — and are not a second lookup key. The service type codes, the
      # service date, and the payer identifier are the outcome's question
      # (see `EligibilityResponse.outcome_for`). `as_of` is the injected clock,
      # not a date from the file. A missing fixture and a file the reader
      # rejects as malformed both answer `:undetermined` with no plans, no
      # errors, and no raw reference — nothing taken from the identifier or
      # the file body. The argument has to be an `EligibilityInquiry`.
      def check_eligibility(inquiry)
        require_eligibility_inquiry!(inquiry)
        as_of = @clock.call
        parsed = read_eligibility_fixture(inquiry.member_identifier)
        eligibility_response(parsed, inquiry, as_of)
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

      def read_eligibility_fixture(member_identifier)
        path = eligibility_fixture_path(member_identifier)
        return nil if path.nil? || !File.file?(path)

        Edi271Reader.new(File.binread(path)).parse
      rescue SystemCallError, Edi271Reader::MalformedError
        nil
      end

      # The raw identifier, not a stripped one. " MBR-X" and "MBR-X\n" are
      # not tokens and must not open MBR-X's fixture.
      def eligibility_fixture_path(member_identifier)
        token = member_identifier.to_s
        return nil unless token.match?(MEMBER_TOKEN)

        directory = File.expand_path(@eligibility_fixture_dir.to_s)
        candidate = File.expand_path("#{token}.271", directory)
        return nil unless contained_in?(directory, candidate)

        candidate
      rescue SystemCallError
        nil
      end

      def contained_in?(directory, candidate)
        return false unless candidate.start_with?("#{directory}#{File::SEPARATOR}")
        return true unless File.exist?(candidate)

        root = "#{File.realpath(directory)}#{File::SEPARATOR}"
        File.realpath(candidate).start_with?(root)
      end

      def eligibility_response(parsed, inquiry, as_of)
        return undetermined_eligibility(as_of) if parsed.nil?

        EligibilityResponse.new(
          outcome: EligibilityResponse.outcome_for(
            plans: parsed.plans,
            errors: parsed.errors,
            service_type_codes: inquiry.service_type_codes,
            service_date: inquiry.service_date,
            payer_identifier: inquiry.payer_identifier
          ),
          plans: parsed.plans,
          errors: parsed.errors,
          as_of: as_of,
          raw_reference: parsed.raw_reference
        )
      end

      def undetermined_eligibility(as_of)
        EligibilityResponse.new(
          outcome: :undetermined,
          plans: [],
          errors: [],
          as_of: as_of,
          raw_reference: nil
        )
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
