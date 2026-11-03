# frozen_string_literal: true

require_relative "acknowledgment"
require_relative "claim_status"
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
    # Implementations must be substitutable: `submit_claim` always answers with
    # an `Acknowledgment` (accepted or rejected — never a denial, which can
    # only come back on an 835), `fetch_remittances` always answers with
    # `Remittance` values, and `check_claim_status` always answers with a
    # `ClaimStatus`. A status inquiry is a 276/277, not an acknowledgment and
    # not an 835: a front-end rejection and an adjudicated denial stay
    # different categories on that answer.
    class ClearinghouseClient
      class TransportError < StandardError; end

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

      # Ask whether one claim is acknowledged, pending, paid, denied, rejected,
      # or not on file (276 request, 277 response).
      #
      # This is not `submit_claim` and not `fetch_remittances`. The category on
      # the answer keeps a front-end rejection distinct from an adjudicated
      # denial. Only F1 is paid, and only F2 is a denial. The base class does
      # not invent a status.
      #
      # @param claim_identifier [String]
      # @return [Corvid::Rcm::ClaimStatus]
      def check_claim_status(claim_identifier)
        raise NotImplementedError, "#{self.class}#check_claim_status not implemented"
      end
    end
  end
end
