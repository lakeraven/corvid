# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "corvid/value_objects"

class Corvid::ValueObjectsTest < Minitest::Test
  # -- PatientReference -------------------------------------------------------

  def test_patient_reference_has_expected_fields
    assert_equal %i[identifier display_name dob sex ssn_last4],
                 Corvid::PatientReference.members
  end

  def test_patient_reference_full_name_aliases_display_name
    pt = Corvid::PatientReference.new(
      identifier: "pt_test", display_name: "TEST,PATIENT",
      dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "0000"
    )
    assert_equal "TEST,PATIENT", pt.full_name
  end

  def test_patient_reference_is_immutable
    pt = Corvid::PatientReference.new(
      identifier: "pt_test", display_name: "TEST,PATIENT",
      dob: nil, sex: nil, ssn_last4: nil
    )
    assert pt.frozen?
  end

  # -- PractitionerReference --------------------------------------------------

  def test_practitioner_reference_has_expected_fields
    assert_equal %i[identifier display_name npi specialty],
                 Corvid::PractitionerReference.members
  end

  def test_practitioner_reference_full_name_aliases_display_name
    pr = Corvid::PractitionerReference.new(
      identifier: "pr_test", display_name: "TEST,PROVIDER", npi: "0000000000", specialty: "TEST"
    )
    assert_equal "TEST,PROVIDER", pr.full_name
  end

  # -- ReferralReference ------------------------------------------------------

  def test_referral_reference_has_expected_fields
    expected = %i[
      identifier patient_identifier status reason_token
      estimated_cost medical_priority_level authorization_number
      emergent urgent chs_approval_status service_requested
    ]
    assert_equal expected, Corvid::ReferralReference.members
  end

  def test_referral_reference_emergent_predicate
    emergent = build_referral(emergent: true, urgent: false)
    refute build_referral(emergent: false).emergent?
    assert emergent.emergent?
  end

  def test_referral_reference_urgent_predicate
    urgent = build_referral(emergent: false, urgent: true)
    refute build_referral(urgent: false).urgent?
    assert urgent.urgent?
  end

  def test_referral_reference_authorization_number_is_not_a_token
    ref = build_referral(authorization_number: "AUTH-2024-001")
    # authorization_number is a business value, not an opaque token
    assert_equal "AUTH-2024-001", ref.authorization_number
    refute_match(/\A[a-z]+_/, ref.authorization_number)
  end

  # -- CareTeamMemberReference ------------------------------------------------

  def test_care_team_member_reference_has_expected_fields
    assert_equal %i[practitioner_identifier role name status],
                 Corvid::CareTeamMemberReference.members
  end

  # -- All references use *_identifier, never *_id ---------------------------

  def test_no_value_object_uses_bare_id_field
    [
      Corvid::PatientReference,
      Corvid::PractitionerReference,
      Corvid::ReferralReference,
      Corvid::CareTeamMemberReference
    ].each do |klass|
      members = klass.members.map(&:to_s)
      bare_ids = members.select { |m| m == "id" || m.end_with?("_id") }
      assert_empty bare_ids, "#{klass} should not use id/*_id (use identifier/*_identifier per ADR 0001)"
    end
  end

  private

  def build_referral(**overrides)
    defaults = {
      identifier: "rf_test",
      patient_identifier: "pt_test",
      status: "pending",
      reason_token: nil,
      estimated_cost: 1000,
      medical_priority_level: 3,
      authorization_number: nil,
      emergent: false,
      urgent: false,
      chs_approval_status: "P",
      service_requested: nil
    }
    Corvid::ReferralReference.new(**defaults.merge(overrides))
  end
end
