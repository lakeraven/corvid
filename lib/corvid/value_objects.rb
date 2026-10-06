# frozen_string_literal: true

# Value objects returned by the Corvid adapter. Per ADR 0001, they use
# `identifier` and `*_identifier` for opaque external/vault tokens, never
# `id` or `*_id` (those are reserved for Rails keys).
#
# Per ADR 0003, these are tokenized references — `identifier` is the vault
# token, not a database ID. Free-text fields are also tokens (e.g.
# ReferralReference#reason_token).

module Corvid
  # american_indian_alaska_native is optional (defaults to nil/"unknown",
  # never false-by-omission) so adapters that don't source race/ethnicity
  # data (e.g. FhirAdapter today) keep working without asserting a negative.
  PatientReference = Data.define(:identifier, :display_name, :dob, :sex, :ssn_last4,
    :american_indian_alaska_native) do
    def initialize(american_indian_alaska_native: nil, **rest)
      super(**rest, american_indian_alaska_native: american_indian_alaska_native)
    end

    def full_name = display_name
    def american_indian_alaska_native? = american_indian_alaska_native == true
  end

  PractitionerReference = Data.define(:identifier, :display_name, :npi, :specialty) do
    def full_name = display_name
  end

  # rendering_provider_identifier and service_site are optional (default
  # nil) so existing adapter builders that don't pass them keep working.
  # service_site distinguishes care rendered at the tribal facility itself
  # from care referred out to a non-tribal specialist — corvid#546 federal
  # share classification needs this to know which Prong applies.
  ReferralReference = Data.define(
    :identifier,
    :patient_identifier,
    :status,
    :reason_token,
    :estimated_cost,
    :medical_priority_level,
    :authorization_number,
    :emergent,
    :urgent,
    :chs_approval_status,
    :service_requested,
    :requesting_provider_identifier,
    :rendering_provider_identifier,
    :service_site
  ) do
    def initialize(rendering_provider_identifier: nil, service_site: nil, **rest)
      super(**rest, rendering_provider_identifier: rendering_provider_identifier, service_site: service_site)
    end

    def emergent? = emergent == true
    def urgent? = urgent == true
    def outside_specialist? = service_site == "non_tribal_specialist"
  end

  CareTeamMemberReference = Data.define(:practitioner_identifier, :role, :name, :status)

  # One billed line item from a stock FHIR R4 `Claim` (or ExplanationOfBenefit)
  # resource. This is the EHR-agnostic shape the generic FhirAdapter emits for
  # purchased/referred-care charges so PRC ingest can create a PrcObligation
  # without knowing anything about the source EHR. `procedure_code` is the
  # billed CPT/HCPCS read straight off the claim line (no vendor shorthand);
  # `billed_amount` is a BigDecimal in `currency`.
  #
  # `amount_error` distinguishes an ABSENT amount (legit nil, no error) from a
  # PRESENT-but-unparseable one (billed_amount nil, amount_error set to a
  # human-readable reason). Callers can then surface the malformed line instead
  # of silently swallowing it. Defaults to nil so existing constructors that
  # don't set it keep working.
  ClaimLineReference = Data.define(
    :claim_identifier,
    :patient_identifier,
    :provider_identifier,
    :procedure_code,
    :procedure_display,
    :serviced_date,
    :billed_amount,
    :currency,
    :sequence,
    :amount_error
  ) do
    def initialize(amount_error: nil, **rest)
      super(amount_error: amount_error, **rest)
    end
  end
end
