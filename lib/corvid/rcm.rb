# frozen_string_literal: true

require_relative "rcm/claim"
require_relative "rcm/charge_builder"
require_relative "rcm/acknowledgment"
require_relative "rcm/remittance"
require_relative "rcm/edi_835_reader"
require_relative "rcm/adjustment_reason_codes"
require_relative "rcm/remittance_classifier"
require_relative "rcm/clearinghouse_client"
require_relative "rcm/fixture_clearinghouse_client"
require_relative "rcm/scrub_ruleset"
require_relative "rcm/scrub_checks"
require_relative "rcm/scrubber"

module Corvid
  # Revenue cycle management.
  #
  # Phase 0 is plain Ruby: no ActiveRecord, no migrations, no network. It
  # loads and runs without a database, which is what makes it testable today.
  #
  # What is here:
  #   Claim / ClaimLine / Coverage / Diagnosis  — FHIR R4-shaped inputs
  #   ChargeBuilder / ChargeSet                 — finished encounter to lines
  #   Scrubber + ScrubRuleset                   — versioned scrub rules as data
  #   ClearinghouseClient                       — the EDI seam
  #   FixtureClearinghouseClient                — synthetic 835s, no payer needed
  #   Edi835Reader                              — X12 835 -> ClaimResponse shapes
  #   AdjustmentReasonCodes                     — CARC/RARC mapping as data
  #   RemittanceClassifier                      — routing, with unmapped -> human
  #
  # ChargeBuilder turns a finished Encounter and its Procedures, Conditions,
  # and Coverage into an in-memory ChargeSet. It reads hashes only. It does
  # not call an adapter and it does not persist. Prices come from the injected
  # price list. Lines carry codes, amounts, tokens, and references, not names,
  # birth dates, or narrative text (ADR 0003).
  #
  # What is deliberately NOT here (wave 2 and later, per the marker issue):
  #   - persistence of any kind (tables, models, the claim event log with #507)
  #   - work queues as durable objects rather than routing destinations
  #   - collections-fee accrual and invoicing
  #   - live clearinghouse transport
  #   - eligibility 270/271 and carve-out routing
  #
  # Two distinctions the whole module is built around, kept in separate files
  # so they cannot blur:
  #
  #   REJECTION — refused at the front door (999/277CA), never adjudicated,
  #               fix-and-resubmit. See Acknowledgment.
  #   DENIAL    — adjudicated refusal to pay on the 835, appeal or write off.
  #               See RemittanceClaim.
  module Rcm
  end
end
