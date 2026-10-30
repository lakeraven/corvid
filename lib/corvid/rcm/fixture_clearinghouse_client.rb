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
    #
    # `submit_claim` returns the immediate front-door acknowledgment and
    # records a later one. The immediate `received_at` is the first call to
    # the injected clock; the later `received_at` is a second call made after
    # that. Each call must return a Time. Both acknowledgments, and both
    # clock readings, are computed before anything is recorded. A submit that
    # raises records nothing. `fetch_acknowledgments` returns those later
    # acknowledgments in submission order and does not read the clock. A
    # canned `delayed_rejection` stays accepted at the front door — the
    # clearinghouse took the claim — and is rejected later with the payer's
    # 277CA edits. A front-door rejection, such as a missing billing provider
    # NPI, is rejected immediately and the later acknowledgment repeats it. A
    # delayed rejection is still subject to that front-door rule. A delayed
    # rejection with no usable edit fails closed at submit.
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

      # Fixed text. A corrupt delayed_rejection row must not echo a claim id
      # or anything from the patient into the error.
      DELAYED_REJECTION_EDIT_MESSAGE =
        "delayed rejection requires one or more edits, each with a non-blank code and description"

      # Fixed text. A clock reading that is not a Time must not be stored.
      CLOCK_MUST_RETURN_TIME_MESSAGE = "clock must return a Time"

      def initialize(scenarios: SCENARIOS, fixture_dir: FIXTURE_DIR,
                     acknowledgment_table: ACKNOWLEDGMENT_TABLE, clock: -> { Time.now.utc })
        @scenarios = Array(scenarios)
        @fixture_dir = fixture_dir
        @clock = clock
        @table = YAML.safe_load_file(acknowledgment_table)
        @submitted = []
        @later_acknowledgments = []
      end

      # Claims `submit_claim` recorded, in order. Phase 0's stand-in for the
      # submission event log (wave 2, with #507). A submit that raises records
      # nothing.
      attr_reader :submitted

      # Returns the immediate front-door acknowledgment and keeps the later
      # one for `fetch_acknowledgments`. The delayed-row check, both
      # acknowledgments, and both clock readings finish before `submitted` or
      # the later list changes. A submit that raises records nothing.
      def submit_claim(claim)
        assert_delayed_rejection_has_usable_edit!(claim)
        immediate = immediate_acknowledgment(claim)
        later = later_acknowledgment(claim, immediate)
        @submitted << claim
        @later_acknowledgments << later
        immediate
      end

      # Later acknowledgments recorded by `submit_claim`, in submission order.
      # Does not read the clock; each `received_at` was stamped at submit.
      def fetch_acknowledgments(since: nil)
        ensure_since_is_time!(since)
        selected_later_acknowledgments(since).dup
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

      def assert_delayed_rejection_has_usable_edit!(claim)
        return unless delayed_rejection?(claim)
        return if delayed_edits_usable?(claim)

        raise ArgumentError, DELAYED_REJECTION_EDIT_MESSAGE
      end

      def delayed_rejection?(claim)
        rejections.dig(claim.identifier.to_s, "delayed_rejection") == true
      end

      # Every listed edit must be usable. A blank code or description is not
      # a payer edit we can route, so the row fails closed instead of being
      # dropped or half-applied.
      def delayed_edits_usable?(claim)
        edits = raw_edits(claim)
        !edits.empty? && edits.all? { |edit| usable_edit?(edit) }
      end

      def raw_edits(claim)
        Array(rejections.dig(claim.identifier.to_s, "edits"))
      end

      def usable_edit?(edit)
        return false unless edit.is_a?(Hash)

        non_blank_string?(edit["code"]) && non_blank_string?(edit["description"])
      end

      def non_blank_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def immediate_acknowledgment(claim)
        edits = immediate_rejection_edits(claim)
        return acceptance_acknowledgment(claim) if edits.empty?

        rejection_acknowledgment(
          claim,
          transaction_set: transaction_set_for(claim),
          edits: edits
        )
      end

      # Canned rejections that are not delayed still win over the billing-NPI
      # check, as they did before later acknowledgments existed. A delayed
      # row is not an immediate rejection; only the front-door rules are.
      def immediate_rejection_edits(claim)
        unless delayed_rejection?(claim)
          canned = canned_edits(claim)
          return canned if canned.any?
        end

        missing_billing_npi_edits(claim)
      end

      def missing_billing_npi_edits(claim)
        return [] unless claim.billing_provider_npi.to_s.strip.empty?

        [ MISSING_BILLING_NPI_EDIT ]
      end

      def later_acknowledgment(claim, immediate)
        if immediate.rejected?
          later_rejection(
            claim,
            transaction_set: immediate.transaction_set,
            edits: immediate.edits
          )
        elsif delayed_rejection?(claim)
          later_delayed_rejection(claim)
        else
          acceptance_acknowledgment(claim, later: true)
        end
      end

      def later_delayed_rejection(claim)
        later_rejection(
          claim,
          transaction_set: transaction_set_for(claim),
          edits: canned_edits(claim)
        )
      end

      def later_rejection(claim, transaction_set:, edits:)
        rejection_acknowledgment(
          claim,
          transaction_set: transaction_set,
          edits: edits,
          later: true
        )
      end

      def acceptance_acknowledgment(claim, later: false)
        build_acknowledgment(
          claim,
          :accepted,
          transaction_set: default_transaction_set,
          later: later
        )
      end

      def rejection_acknowledgment(claim, transaction_set:, edits:, later: false)
        build_acknowledgment(
          claim,
          :rejected,
          transaction_set: transaction_set,
          edits: edits,
          later: later
        )
      end

      def canned_edits(claim)
        raw_edits(claim).map { |edit| acknowledgment_edit(edit) }
      end

      def acknowledgment_edit(edit)
        AcknowledgmentEdit.new(
          code: edit.fetch("code"),
          description: edit.fetch("description"),
          element: edit["element"],
          level: edit.fetch("level", "claim")
        )
      end

      # `submit_claim` builds the immediate acknowledgment first and the later
      # one second, so the later `received_at` is the second reading. Fetch
      # does not build acknowledgments.
      def build_acknowledgment(claim, outcome, transaction_set:, edits: [], later: false)
        Acknowledgment.new(
          claim_identifier: claim.identifier,
          trace_number: acknowledgment_trace_number(claim, later: later),
          outcome: outcome,
          transaction_set: transaction_set,
          received_at: read_clock,
          edits: edits.dup
        )
      end

      # The later trace is this submission's place in the log. The
      # acknowledgment is built before the claim is appended, so the suffix
      # is one past the claims already recorded.
      def acknowledgment_trace_number(claim, later:)
        return "ACK-#{claim.identifier}" unless later

        "ACK-#{claim.identifier}-LATER-#{@submitted.length + 1}"
      end

      # Only call site for the injected clock. Each reading must be a Time;
      # `submit_claim` takes both readings before it records anything.
      def read_clock
        reading = @clock.call
        return reading if reading.is_a?(Time)

        raise ArgumentError, CLOCK_MUST_RETURN_TIME_MESSAGE
      end

      def ensure_since_is_time!(since)
        return if since.nil? || since.is_a?(Time)

        raise ArgumentError, "since must be a Time"
      end

      def selected_later_acknowledgments(since)
        return @later_acknowledgments if since.nil?

        @later_acknowledgments.select { |later| later.received_at >= since }
      end
    end
  end
end
