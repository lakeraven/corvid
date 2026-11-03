# frozen_string_literal: true

require_relative "rcm/claim"
require_relative "rcm/acknowledgment"
require_relative "rcm/remittance"
require_relative "rcm/edi_835_reader"
require_relative "rcm/adjustment_reason_codes"
require_relative "rcm/remittance_classifier"
require_relative "rcm/claim_status"
require_relative "rcm/clearinghouse_client"
require_relative "rcm/fixture_clearinghouse_client"
require_relative "rcm/scrub_ruleset"
require_relative "rcm/scrub_checks"
require_relative "rcm/scrubber"

module Corvid
  # Revenue cycle management.
  #
  # Phase 0 (this slice) is fixtures and rules and nothing else: plain Ruby, no
  # ActiveRecord, no migrations, no network. It loads and runs without a
  # database, which is what makes it testable today.
  #
  # What is here:
  #   Claim / ClaimLine / Coverage / Diagnosis  — FHIR R4-shaped inputs
  #   Scrubber + ScrubRuleset                   — versioned scrub rules as data
  #   ClaimStatus                               — typed 276/277 claim status
  #   ClearinghouseClient                       — the EDI seam
  #   FixtureClearinghouseClient                — synthetic 835s and 277s, no payer
  #   Edi835Reader                              — X12 835 -> ClaimResponse shapes
  #   AdjustmentReasonCodes                     — CARC/RARC mapping as data
  #   RemittanceClassifier                      — routing, with unmapped -> human
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
  #               fix-and-resubmit. See Acknowledgment. On a 276/277 status
  #               inquiry the same fact is category :rejected (A3, A6, A7, A8).
  #   DENIAL    — adjudicated refusal to pay, appeal or write off. On an 835
  #               see RemittanceClaim. On a 276/277 inquiry only F2 is category
  #               :finalized_denied. See ClaimStatus.
  #
  # A status inquiry is neither of those documents. ClaimStatus reports one
  # category. Only F1 is paid. F0, F3, F3F, F3N, F4, and the E-codes are
  # undetermined: a human decides. A category code that is not in the table is
  # undetermined too — never paid, never denied.
  module Rcm
  end
end
