# frozen_string_literal: true

require_relative "acknowledgment"
require_relative "remittance"
require_relative "eligibility"

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
    # `Remittance` values, and `check_eligibility` always answers with an
    # `EligibilityResponse`.
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

      # Real-time eligibility (X12 271).
      #
      # Unknown is never a no. Only an explicit inactive answer is `:inactive`;
      # an error, a timeout, or an unmapped answer is `:undetermined`
      # (42 CFR 136.61). Whatever this raises must not name the patient or the
      # member — the inquiry is not interpolated into the message.
      #
      # @param inquiry [Corvid::Rcm::EligibilityInquiry]
      # @return [Corvid::Rcm::EligibilityResponse]
      def check_eligibility(inquiry)
        raise NotImplementedError, "#{self.class}#check_eligibility not implemented"
      end
    end
  end
end
