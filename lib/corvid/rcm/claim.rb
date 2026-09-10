# frozen_string_literal: true

require "date"

module Corvid
  module Rcm
    # In-memory, FHIR R4-shaped inputs to the RCM pipeline.
    #
    # Per ADR 0003 these are *boundary* shapes: they are assembled in memory
    # from adapter reads, handed to the scrubber and the clearinghouse client,
    # and dropped. Corvid persists none of it. Phase 0 ships no tables at all —
    # DB persistence is wave 2.
    #
    # Field names follow FHIR R4 so a reader who knows `Claim`, `Coverage`, and
    # `ClaimResponse` can read this without a translation table:
    #
    #   Corvid::Rcm::Claim        <- FHIR R4 Claim (use = "claim", type = "professional")
    #   Corvid::Rcm::ClaimLine    <- FHIR R4 Claim.item
    #   Corvid::Rcm::Diagnosis    <- FHIR R4 Claim.diagnosis
    #   Corvid::Rcm::Coverage     <- FHIR R4 Coverage (reached via Claim.insurance)
    #
    # These are plain `Data` value objects rather than `FHIR::Claim` instances
    # because Corvid carries no FHIR model gem and Phase 0 deliberately adds no
    # dependency. The existing generic `FhirAdapter` reads stock FHIR JSON as
    # hashes and flattens it into `Corvid::ClaimLineReference` the same way;
    # `ClaimLine.from_claim_line_reference` bridges that existing shape into
    # this one, so the adapter layer stays the single reader of stock FHIR.

    # FHIR R4 Claim.diagnosis. `code` is ICD-10-CM.
    Diagnosis = Data.define(:sequence, :code, :system) do
      def initialize(sequence:, code:, system: "http://hl7.org/fhir/sid/icd-10-cm")
        super
      end

      # ICD-10-CM category header, e.g. "F32" — the three-character rubric.
      # Never billable on a claim; a subcategory is always required.
      def category_header?
        code.to_s.delete(".").length <= 3
      end

      def chapter_letter
        code.to_s[0]
      end
    end

    # FHIR R4 Claim.item — one billed service line.
    #
    # `encounter_modality` and `documented_minutes` are clinical facts that ride
    # on FHIR as `Claim.supportingInfo`; they are lifted onto the line here
    # because every Phase 0 scrub rule that needs them is line-scoped.
    #
    # `encounter_modality` is one of:
    #   :in_person                 — patient physically present at the practice
    #   :telehealth_patient_home   — two-way audio/video, patient at home
    #   :telehealth_other          — two-way audio/video, patient at another site
    #   :audio_only                — telephone, no video
    ClaimLine = Data.define(
      :sequence,
      :procedure_code,
      :modifiers,
      :place_of_service,
      :encounter_modality,
      :serviced_date,
      :billed_amount,
      :currency,
      :units,
      :documented_minutes,
      :diagnosis_sequences
    ) do
      def initialize(sequence:, procedure_code:, serviced_date:, billed_amount:,
                     modifiers: [], place_of_service: nil, encounter_modality: nil,
                     currency: "USD", units: 1, documented_minutes: nil,
                     diagnosis_sequences: [ 1 ])
        super
      end

      # Bridge from `Corvid::ClaimLineReference`, the shape the generic
      # FhirAdapter already flattens stock FHIR R4 `Claim.item` into.
      #
      # The encounter facts a scrub rule needs — how the session happened, where
      # it was billed from, how many minutes are documented — are not on a
      # billed line in FHIR; they live in `Claim.supportingInfo`. The caller
      # passes them in rather than having them defaulted to something plausible
      # and wrong: a line with no recorded modality BLOCKS at scrub time, which
      # is the right answer when nobody knows how the visit happened.
      def self.from_claim_line_reference(reference, **encounter_facts)
        new(
          sequence: reference.sequence || 1,
          procedure_code: reference.procedure_code,
          serviced_date: reference.serviced_date,
          billed_amount: reference.billed_amount,
          currency: reference.currency || "USD",
          **encounter_facts
        )
      end

      def modifier?(code)
        Array(modifiers).map(&:to_s).include?(code.to_s)
      end

      def telehealth?
        %i[telehealth_patient_home telehealth_other audio_only].include?(encounter_modality)
      end

      def to_s
        "line #{sequence} (#{procedure_code})"
      end
    end

    # FHIR R4 Coverage, reached from Claim.insurance. `timely_filing_days` is
    # the payer's filing window; it is plan configuration, not a contract term,
    # and is supplied per tenant.
    Coverage = Data.define(
      :identifier,
      :payer_identifier,
      :payer_name,
      :status,
      :relationship,
      :subscriber_identifier,
      :subscriber_given_name,
      :subscriber_family_name,
      :subscriber_birth_date,
      :subscriber_gender,
      :period_start,
      :period_end,
      :timely_filing_days,
      :audio_only_modifier
    ) do
      def initialize(payer_identifier:, identifier: nil, payer_name: nil, status: "active",
                     relationship: "self", subscriber_identifier: nil,
                     subscriber_given_name: nil, subscriber_family_name: nil,
                     subscriber_birth_date: nil, subscriber_gender: nil,
                     period_start: nil, period_end: nil, timely_filing_days: nil,
                     audio_only_modifier: nil)
        super
      end

      def self_relationship?
        relationship.to_s == "self"
      end

      def active?
        status.to_s == "active"
      end
    end

    # FHIR R4 Claim. Professional (837P) only in Phase 0.
    Claim = Data.define(
      :identifier,
      :tenant_identifier,
      :claim_type,
      :patient_identifier,
      :patient_given_name,
      :patient_family_name,
      :patient_birth_date,
      :patient_gender,
      :billing_provider_npi,
      :billing_provider_tax_id,
      :rendering_provider_npi,
      :rendering_provider_taxonomy,
      :coverage,
      :diagnoses,
      :items,
      :created
    ) do
      def initialize(identifier:, patient_identifier:, coverage: nil, tenant_identifier: nil,
                     claim_type: "professional", patient_given_name: nil,
                     patient_family_name: nil, patient_birth_date: nil, patient_gender: nil,
                     billing_provider_npi: nil, billing_provider_tax_id: nil,
                     rendering_provider_npi: nil, rendering_provider_taxonomy: nil,
                     diagnoses: [], items: [], created: nil)
        super
      end

      def total_billed
        Array(items).sum(0) { |item| item.billed_amount.to_f }
      end

      def earliest_service_date
        Array(items).filter_map(&:serviced_date).min
      end

      def payer_identifier
        coverage&.payer_identifier
      end
    end

    # One previously-adjudicated or previously-submitted service, used by the
    # duplicate and repeat-encounter rules. Callers supply the window they care
    # about; the scrubber never queries anything itself.
    PriorService = Data.define(
      :claim_identifier, :patient_identifier, :rendering_provider_npi,
      :procedure_code, :serviced_date
    ) do
      def initialize(patient_identifier:, procedure_code:, serviced_date:,
                     claim_identifier: nil, rendering_provider_npi: nil)
        super
      end
    end

    # Read-only view over prior services. Phase 0 keeps this in memory; wave 2
    # backs it with the claim event log (#507).
    class ClaimHistory
      def initialize(services = [])
        @services = Array(services)
      end

      attr_reader :services

      def self.empty
        new([])
      end

      # Same patient, same date of service, same procedure code — the classic
      # duplicate that earns a CO-18 if it reaches the payer.
      def duplicates_of(patient_identifier:, procedure_code:, serviced_date:, excluding_claim_identifier: nil)
        @services.select do |prior|
          prior.patient_identifier == patient_identifier &&
            prior.procedure_code == procedure_code &&
            prior.serviced_date == serviced_date &&
            prior.claim_identifier != excluding_claim_identifier
        end
      end

      def services_for(patient_identifier:, procedure_code:, rendering_provider_npi: nil, on_or_after: nil)
        @services.select do |prior|
          prior.patient_identifier == patient_identifier &&
            prior.procedure_code == procedure_code &&
            (rendering_provider_npi.nil? || prior.rendering_provider_npi == rendering_provider_npi) &&
            (on_or_after.nil? || (prior.serviced_date && prior.serviced_date >= on_or_after))
        end
      end
    end
  end
end
