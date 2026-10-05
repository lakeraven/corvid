# frozen_string_literal: true

require_relative "acknowledgment"
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
    # only come back on an 835), and `fetch_remittances` always answers with
    # `Remittance` values.
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
      # @param since [Date, nil] only remittances paid on or after this date
      # @return [Array<Corvid::Rcm::Remittance>]
      def fetch_remittances(since: nil)
        raise NotImplementedError, "#{self.class}#fetch_remittances not implemented"
      end
    end
  end
end
