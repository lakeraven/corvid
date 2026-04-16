# frozen_string_literal: true

module Corvid
  # CMS-0057-F Prior Authorization API (Da Vinci PAS) serialization.
  #
  # Translates between corvid's PrcReferral domain model and FHIR Claim /
  # ClaimResponse resources per the Da Vinci PAS Implementation Guide.
  #
  # Host apps wire these into FHIR endpoints:
  #   POST /Claim/$submit           -> submit_from_claim(fhir_claim_hash)
  #   GET /ClaimResponse/{id}       -> claim_response_for(referral)
  #   GET /Bundle?ClaimResponse...  -> bundle_for_patient(patient_identifier)
  #
  # SCOPE: This is a PAS-shaped foundation, not a conformance-complete
  # implementation. It emits resource shapes with the fields corvid tracks
  # today; it does NOT yet emit Da Vinci PAS profiles, extension URLs,
  # Insurance/coverage references, item detail, or the X12 278 bridge
  # (issue #47). Formal CMS-0057-F certification requires IG-driven
  # validation and a richer mapping layer.
  #
  # Reference: https://hl7.org/fhir/us/davinci-pas/
  class PriorAuthorizationApiService
    # Map PrcReferral AASM status -> FHIR ClaimResponse disposition + outcome.
    STATUS_TO_DISPOSITION = {
      "draft"                   => { outcome: "queued",   disposition: "draft" },
      "submitted"               => { outcome: "queued",   disposition: "submitted" },
      "eligibility_review"      => { outcome: "queued",   disposition: "pended" },
      "management_approval"     => { outcome: "queued",   disposition: "pended" },
      "alternate_resource_review" => { outcome: "queued", disposition: "pended" },
      "priority_assignment"     => { outcome: "queued",   disposition: "pended" },
      "committee_review"        => { outcome: "queued",   disposition: "pended" },
      "exception_review"        => { outcome: "queued",   disposition: "pended" },
      "authorized"              => { outcome: "complete", disposition: "approved" },
      "denied"                  => { outcome: "complete", disposition: "denied" },
      "deferred"                => { outcome: "queued",   disposition: "pended" },
      "cancelled"               => { outcome: "error",    disposition: "cancelled" }
    }.freeze

    class << self
      # POST /Claim/$submit handler. Accepts a FHIR Claim (as hash) and
      # creates a PrcReferral. Returns a ClaimResponse hash.
      #
      # Hosts pass app_identifier (the authenticated OAuth client_id) so
      # CMS-0057-F annual usage metrics (#46) can count distinct apps.
      def submit_from_claim(fhir_claim, app_identifier: nil)
        patient_id = extract_patient_identifier(fhir_claim)
        provider_id = extract_provider_identifier(fhir_claim)
        service_description = extract_service_description(fhir_claim)
        estimated_cost = extract_estimated_cost(fhir_claim)

        # Scope the find by facility so patients with cases at multiple
        # facilities in the same tenant don't attach a PA to the wrong case.
        # Tenant is applied automatically by TenantScoped#default_scope.
        facility_id = Corvid::TenantContext.current_facility_identifier
        kase = Corvid::Case.find_or_create_by!(
          patient_identifier: patient_id,
          facility_identifier: facility_id
        )

        referral_id = Corvid.adapter.create_referral(patient_id, {
          service_requested: service_description,
          reason: service_description,
          estimated_cost: estimated_cost,
          requesting_provider_identifier: provider_id
        })

        referral = Corvid::PrcReferral.create!(
          case: kase,
          referral_identifier: referral_id,
          estimated_cost: estimated_cost,
          facility_identifier: kase.facility_identifier,
          current_activity: "Submitted via FHIR PAS"
        )
        referral.submit!

        Corvid::ApiMetricsService.record!(
          api: :pas, endpoint: "submit",
          patient_identifier: patient_id,
          app_identifier: app_identifier
        )

        claim_response_for(referral)
      end

      # GET /ClaimResponse/{id} handler. Records a "read" metrics event and
      # returns the serialized response. Internal callers that already
      # counted a different endpoint (submit / search) should use
      # claim_response_for directly to avoid double-counting.
      def read_claim_response(referral, app_identifier: nil)
        Corvid::ApiMetricsService.record!(
          api: :pas, endpoint: "read",
          patient_identifier: referral.case.patient_identifier,
          app_identifier: app_identifier
        )
        claim_response_for(referral)
      end

      # Generate a FHIR ClaimResponse for a PrcReferral. Pure serializer —
      # does not record a metrics event (the caller's endpoint does).
      def claim_response_for(referral)
        mapping = STATUS_TO_DISPOSITION.fetch(referral.status,
          { outcome: "queued", disposition: "pended" })

        response = {
          resourceType: "ClaimResponse",
          id: referral.referral_identifier,
          status: "active",
          type: { coding: [{ system: "http://terminology.hl7.org/CodeSystem/claim-type",
                             code: "professional" }] },
          use: "preauthorization",
          patient: { reference: "Patient/#{referral.case.patient_identifier}" },
          created: referral.created_at.iso8601,
          # insurer is required by FHIR R4 ClaimResponse profile but
          # facility_identifier is nullable on PrcReferral; omit the reference
          # when we can't build a valid one rather than emitting "Organization/".
          insurer: referral.facility_identifier.present? ?
            { reference: "Organization/#{referral.facility_identifier}" } : nil,
          outcome: mapping[:outcome],
          disposition: mapping[:disposition],
          preAuthRef: referral.authorization_number
        }.compact

        # Collect processNote entries from denial reasons and info-request text.
        # FHIR R4 ClaimResponse.processNote.type is a coded value from the
        # `note-type` valueset (display | print | printoper). Use "display"
        # so the note renders for human review without a constrained code-set
        # validation failure.
        notes = []
        latest = referral.latest_determination
        notes << { type: "display", text: denial_reason(referral, latest) } if latest && latest.outcome == "denied"

        # Pended referrals flagged for review may require additional info.
        # Flagged-for-review overrides disposition to "pended" regardless of
        # underlying workflow state so payers see a consistent status.
        # The "more info needed" signal is surfaced via processNote (a
        # standard R4 ClaimResponse element). A top-level communicationRequest
        # is NOT defined on ClaimResponse in base R4 — Da Vinci PAS models
        # that pattern via Communication resources and IG extensions, which
        # this foundation does not yet emit.
        if referral.status == "deferred" || (referral.flagged_for_review? && !referral.authorized? && !referral.denied?)
          response[:disposition] = "pended" unless referral.authorized? || referral.denied?
          additional_info_for(referral).each do |msg|
            notes << { type: "display", text: msg }
          end
        end

        response[:processNote] = notes if notes.any?
        response
      end

      # Generate a FHIR Bundle of ClaimResponses for a patient.
      # Tenant filtering happens via TenantScoped#default_scope; the
      # PrcReferral.for_patient_identifier scope centralizes the Case join
      # and eager-loads to prevent N+1 case lookups in claim_response_for.
      def bundle_for_patient(patient_identifier, app_identifier: nil)
        referrals = Corvid::PrcReferral.for_patient_identifier(patient_identifier)

        Corvid::ApiMetricsService.record!(
          api: :pas, endpoint: "search",
          patient_identifier: patient_identifier,
          app_identifier: app_identifier
        )

        {
          resourceType: "Bundle",
          type: "searchset",
          total: referrals.count,
          entry: referrals.map do |ref|
            { resource: claim_response_for(ref) }
          end
        }
      end

      # List of covered items and services requiring prior authorization.
      def covered_services(app_identifier: nil)
        Corvid::ApiMetricsService.record!(
          api: :pas, endpoint: "covered_services",
          app_identifier: app_identifier
        )
        {
          resourceType: "Bundle",
          type: "collection",
          entry: [
            { resource: { resourceType: "ActivityDefinition", title: "Cardiology Consultation",
                          kind: "ServiceRequest", status: "active",
                          description: "Requires prior authorization" } },
            { resource: { resourceType: "ActivityDefinition", title: "MRI", kind: "ServiceRequest",
                          status: "active", description: "Requires prior authorization" } },
            { resource: { resourceType: "ActivityDefinition", title: "Surgery", kind: "ServiceRequest",
                          status: "active", description: "Requires prior authorization" } }
          ]
        }
      end

      # Documentation requirements for a specific service (Da Vinci DTR).
      def documentation_requirements_for(service_description, app_identifier: nil)
        Corvid::ApiMetricsService.record!(
          api: :pas, endpoint: "documentation",
          app_identifier: app_identifier
        )
        {
          resourceType: "Questionnaire",
          title: "Documentation requirements for #{service_description}",
          status: "active",
          item: [
            { linkId: "clinical_justification", text: "Clinical justification", type: "text", required: true },
            { linkId: "diagnosis_codes", text: "Diagnosis codes (ICD-10)", type: "string", required: true },
            { linkId: "prior_treatments", text: "Prior treatments attempted", type: "text", required: false }
          ]
        }
      end

      private

      def extract_patient_identifier(fhir_claim)
        ref = fhir_claim.dig(:patient, :reference) || fhir_claim.dig("patient", "reference")
        ref&.split("/")&.last
      end

      def extract_provider_identifier(fhir_claim)
        ref = fhir_claim.dig(:provider, :reference) || fhir_claim.dig("provider", "reference")
        ref&.split("/")&.last
      end

      def extract_service_description(fhir_claim)
        items = fhir_claim[:item] || fhir_claim["item"] || []
        first = items.first || {}
        raw = first[:productOrService] || first["productOrService"]
        normalize_codeable_concept(raw) || "Service"
      end

      # productOrService is a FHIR CodeableConcept — may be a Hash with
      # text/coding in real payloads, or a simple String in lightweight
      # callers. Return a String suitable for persistence as service_requested.
      def normalize_codeable_concept(value)
        case value
        when String
          value
        when Hash
          v = value.transform_keys(&:to_sym)
          v[:text] ||
            v.dig(:coding, 0, :display) ||
            v.dig(:coding, 0, :code)
        end
      end

      def extract_estimated_cost(fhir_claim)
        total = fhir_claim[:total] || fhir_claim["total"] || {}
        total[:value] || total["value"]
      end

      # Resolve human-readable denial text from the vault.
      # NOTE: today the engine stores free-text reasons in deferred_reason_token
      # (a misnomer inherited from the referral model — it covers both
      # deferrals and denials). A follow-up should move denial text onto the
      # Determination's reasons_token so the two cases are separable.
      def denial_reason(referral, determination)
        return "Denial reason not recorded" unless referral.deferred_reason_token

        Corvid.adapter.fetch_text(referral.deferred_reason_token) ||
          "Denied per #{determination.decision_method}"
      end

      def additional_info_for(referral)
        ["Additional clinical documentation requested"]
      end
    end
  end
end
