# frozen_string_literal: true

require_relative "acknowledgment"
require_relative "remittance"
require_relative "payer_directory"

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
    # `Remittance` values, and `search_payers` always answers with
    # `PayerDirectoryEntry` values.
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

      # Search the payer directory.
      #
      # Returns payers whose name contains the stripped, case-insensitive
      # query, or whose payer identifier or an alias exactly matches it.
      # Identifiers and aliases are never matched by substring. Exact
      # identifier and alias matches come first, then name-substring
      # matches, each in directory order, with no duplicates. Blank,
      # whitespace-only, and nil queries return nothing.
      #
      # @param query [String, nil] a name fragment, or an exact payer
      #   identifier or alias
      # @return [Array<Corvid::Rcm::PayerDirectoryEntry>]
      def search_payers(query)
        raise NotImplementedError, "#{self.class}#search_payers not implemented"
      end
    end
  end
end
