# frozen_string_literal: true

require_relative "acknowledgment"
require_relative "claim_validation"
require_relative "remittance"

module Corvid
  module Rcm
    # The seam between Corvid and whatever moves EDI for a tenant.
    #
    # Phase 0 ships this interface and a fixture implementation and nothing
    # else on purpose: no Phase 0 deliverable may depend on a live payer
    # connection, and a real transport (SFTP drops, a vendor REST API, an
    # on-prem gateway) is a per-tenant, contract-bound choice that belongs in a
    # private repo — the same way vendor EHR adapters do (see
    # `Corvid::Adapters::Base`).
    #
    # Implementations must be substitutable: `validate_claim` always answers
    # with a `ClaimValidation` (front-end edits — a rejection, never a
    # denial), `submit_claim` always answers with an `Acknowledgment`
    # (accepted or rejected — never a denial, which can only come back on an
    # 835), and `fetch_remittances` always answers with `Remittance` values.
    # Corvid's own scrub runs first. `validate_claim` runs last and does not
    # submit; only `submit_claim` sends the claim.
    class ClearinghouseClient
      class TransportError < StandardError; end

      # Validate one professional claim against the clearinghouse's front-end
      # edits. Runs after Corvid's own scrub and before `submit_claim`. It
      # does not submit the claim.
      #
      # A failure is a front-end problem, never a denial. The
      # `ClaimValidation` it returns becomes a rejected `Acknowledgment`
      # with transaction_set "validation", which routes like a rejected 277CA.
      #
      # @param claim [Corvid::Rcm::Claim]
      # @return [Corvid::Rcm::ClaimValidation]
      def validate_claim(claim)
        raise NotImplementedError, "#{self.class}#validate_claim not implemented"
      end

      # Submit one professional claim (837P).
      #
      # @param claim [Corvid::Rcm::Claim]
      # @return [Corvid::Rcm::Acknowledgment] the 999/277CA answer to "did this
      #   get in the door?". An accepted acknowledgment is NOT a payment
      #   decision; a rejected one is NOT a denial.
      def submit_claim(claim)
        raise NotImplementedError, "#{self.class}#submit_claim not implemented"
      end

      # Fetch available remittance advice (835).
      #
      # Takes the same `date_range:` keyword as
      # `Corvid::Adapters::Base#fetch_remittances`, so a caller written against
      # the adapter contract is not refused. It answers with typed `Remittance`
      # values rather than the adapter's hashes; an adapter that wants to serve
      # this seam converts at its own boundary.
      #
      # @param date_range [Range<Date>, nil] only remittances paid within it
      #   (endless and beginless ranges allowed)
      # @return [Array<Corvid::Rcm::Remittance>]
      def fetch_remittances(date_range: nil)
        raise NotImplementedError, "#{self.class}#fetch_remittances not implemented"
      end
    end
  end
end
