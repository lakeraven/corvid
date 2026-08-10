# frozen_string_literal: true

module Corvid
  # Produces the documentation a state Medicaid agency needs to honor an
  # AI/AN exemption: what the exemption is, its statutory basis, and the
  # verification provenance that makes it defensible (source, confidence,
  # snapshot hash, when it was verified and by whom).
  #
  # First pass returns a structured attestation Hash. Rendering it to a
  # specific state form or PDF is deferred — the shape here is the stable
  # contract a renderer would consume, and it carries no PHI (person is an
  # opaque token; only provenance metadata is included).
  module ExemptionAttestationService
    STATUTORY_BASIS = "HR-1 (2025 reconciliation) AI/AN Medicaid exemption"

    EXEMPTION_LABELS = {
      "work_requirement" => "Medicaid community-engagement / work requirement",
      "six_month_redetermination" => "6-month eligibility redetermination"
    }.freeze

    class << self
      # Build the attestation for one or more of a person's in-effect
      # exemptions. Pass a MedicaidExemption, an array of them, or a
      # person_identifier (all in-effect exemptions for that person are used).
      #
      # Raises ArgumentError when there is no in-effect exemption to attest —
      # an attestation is only defensible off a verified, asserted exemption.
      def generate(exemption: nil, person_identifier: nil, as_of: Time.current, tenant_identifier: nil)
        tenant_identifier ||= Corvid::TenantContext.current_tenant_identifier
        exemptions = resolve_exemptions(exemption, person_identifier, tenant_identifier, as_of)

        if exemptions.empty?
          raise ArgumentError, "no in-effect exemption to attest for the given subject"
        end

        person = exemptions.first.person_identifier

        {
          statutory_basis: STATUTORY_BASIS,
          person_identifier: person,
          tenant_identifier: tenant_identifier,
          generated_at: Time.current,
          exemptions: exemptions.map { |e| attestation_line(e) }
        }
      end

      private

      def attestation_line(exemption)
        {
          exemption_type: exemption.exemption_type,
          exemption_label: EXEMPTION_LABELS[exemption.exemption_type],
          basis: exemption.basis,
          effective_date: exemption.effective_date,
          expires_at: exemption.expires_at,
          verification: {
            source: exemption.verification_source,
            confidence: exemption.verification_confidence,
            verified_at: exemption.verified_at,
            snapshot_hash: exemption.verification_snapshot_hash,
            asserted_by_identifier: exemption.asserted_by_identifier
          }
        }
      end

      def resolve_exemptions(exemption, person_identifier, tenant_identifier, as_of)
        list =
          if exemption
            Array(exemption)
          elsif person_identifier
            MedicaidExemption
              .where(tenant_identifier: tenant_identifier)
              .for_person(person_identifier)
              .active
              .to_a
          else
            raise ArgumentError, "pass exemption: or person_identifier:"
          end

        list.select { |e| e.in_effect?(as_of: as_of) }
      end
    end
  end
end
