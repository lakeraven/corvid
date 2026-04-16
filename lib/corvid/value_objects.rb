# frozen_string_literal: true

# Value objects returned by the Corvid adapter. Per ADR 0001, they use
# `identifier` and `*_identifier` for opaque external/vault tokens, never
# `id` or `*_id` (those are reserved for Rails keys).
#
# Per ADR 0003, these are tokenized references — `identifier` is the vault
# token, not a database ID. Free-text fields are also tokens (e.g.
# ReferralReference#reason_token).

module Corvid
  PatientReference = Data.define(:identifier, :display_name, :dob, :sex, :ssn_last4) do
    def full_name = display_name
  end

  PractitionerReference = Data.define(:identifier, :display_name, :npi, :specialty) do
    def full_name = display_name
  end

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
    :requesting_provider_identifier
  ) do
    def emergent? = emergent == true
    def urgent? = urgent == true
  end

  CareTeamMemberReference = Data.define(:practitioner_identifier, :role, :name, :status)
end
