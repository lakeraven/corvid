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
    # `EligibilityResponse`. A malformed 271 is that response with outcome
    # `:undetermined`, not a raised parse error.
    class ClearinghouseClient
      class TransportError < StandardError; end

      # Fixed so a rejected argument cannot carry a patient or member token.
      INQUIRY_REQUIRED_MESSAGE = "expected an eligibility inquiry"

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
      # an error, a timeout, a malformed 271, or an unmapped answer is
      # `:undetermined` (42 CFR 136.61). Implementations always return an
      # `EligibilityResponse`: a 271 the reader cannot parse is an
      # undetermined answer, not an exception that carries the inquiry.
      # Whatever this raises must not name the patient or the member — the
      # inquiry is not interpolated into the message. The argument has to be
      # an `EligibilityInquiry`. Anything else raises ArgumentError with
      # {INQUIRY_REQUIRED_MESSAGE}.
      #
      # @param inquiry [Corvid::Rcm::EligibilityInquiry]
      # @return [Corvid::Rcm::EligibilityResponse]
      # @raise [ArgumentError] when `inquiry` is not an {EligibilityInquiry}
      def check_eligibility(inquiry)
        require_eligibility_inquiry!(inquiry)
        raise NotImplementedError, "#{self.class}#check_eligibility not implemented"
      end

      private

      def require_eligibility_inquiry!(inquiry)
        return if inquiry.is_a?(EligibilityInquiry)

        raise ArgumentError, INQUIRY_REQUIRED_MESSAGE
      end
    end
  end
end
