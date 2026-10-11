# frozen_string_literal: true

module Corvid
  # One row per AianExemptionService#determine call: which bases were
  # established and by which sources. Stores no PHI (ADR 0003): evidence rows
  # carry basis, source class and confidence only. The snapshot hash lets an
  # auditor confirm a re-run saw the same upstream data.
  class AianExemptionDetermination < ::ActiveRecord::Base
    self.table_name = "corvid_aian_exemption_determinations"

    include TenantScoped

    STATUSES = %w[exempt not_established unavailable].freeze

    # FHIR R4 VerificationResult.status. A determination that did not
    # establish the exemption is "in-process" — verification continues by
    # attestation or documents — never "val-fail", which would read as a
    # finding that the person is not AI/AN.
    FHIR_STATUS = { "exempt" => "validated", "not_established" => "in-process", "unavailable" => "in-process" }.freeze

    BASIS_SYSTEM = "https://github.com/lakeraven/corvid/aian-exemption-basis"

    validates :person_identifier, presence: true
    validates :decided_at, presence: true
    validates :as_of_date, presence: true
    validates :status, inclusion: { in: STATUSES }

    scope :recent, -> { order(decided_at: :desc) }
    scope :for_person, ->(identifier) { where(person_identifier: identifier) }

    def exempt?
      status == "exempt"
    end

    def to_fhir_verification_result
      {
        resourceType: "VerificationResult",
        id: id.to_s,
        target: [ { reference: "Patient/#{person_identifier}" } ],
        targetLocation: [ "Patient.extension:aianExemption" ],
        status: FHIR_STATUS.fetch(status),
        statusDate: decided_at.iso8601,
        primarySource: evidence.map { |e| primary_source(e) }
      }
    end

    private

    def primary_source(entry)
      {
        who: { display: entry["source"] },
        type: [ { coding: [ { system: BASIS_SYSTEM, code: entry["basis"] } ] } ],
        validationStatus: { coding: [ { code: "successful" } ] }
      }
    end
  end
end
