# frozen_string_literal: true

require "test_helper"

class Corvid::CareTeamRoleCodeAdapterTest < ActiveSupport::TestCase
  SNOMED_SYSTEM = "http://snomed.info/sct"
  SNOMED_PCP_CODE = "446050000"

  setup do
    @fhir_adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://example.test/fhir")
    @mock_adapter = Corvid::Adapters::MockAdapter.new
  end

  def test_care_team_member_reference_exposes_role_code_not_free_text_role
    refute_includes Corvid::CareTeamMemberReference.members, :role
    assert_includes Corvid::CareTeamMemberReference.members, :role_code
  end

  def test_fhir_adapter_maps_snomed_primary_care_physician_to_primary_care_provider
    bundle = care_team_bundle(
      participant_role_coding(system: SNOMED_SYSTEM, code: SNOMED_PCP_CODE, display: "Primary care physician")
    )
    member = fetch_care_team_member(bundle)
    assert_equal "primary_care_provider", member.role_code
  end

  def test_fhir_adapter_maps_unmapped_coding_to_other_without_failing
    bundle = care_team_bundle(
      participant_role_coding(system: SNOMED_SYSTEM, code: "doctor", display: "Doctor")
    )
    member = fetch_care_team_member(bundle)
    assert_equal "other", member.role_code
  end

  def test_fhir_adapter_maps_missing_role_to_other
    bundle = care_team_bundle({ "member" => { "reference" => "Practitioner/pr-map-001" } })
    member = fetch_care_team_member(bundle)
    assert_equal "other", member.role_code
  end

  def test_fhir_adapter_maps_unknown_system_to_other
    bundle = care_team_bundle(
      participant_role_coding(system: "http://example.test/roles", code: SNOMED_PCP_CODE)
    )
    member = fetch_care_team_member(bundle)
    assert_equal "other", member.role_code
  end

  def test_fhir_adapter_maps_non_string_code_to_other
    bundle = care_team_bundle(
      "member" => { "reference" => "Practitioner/pr-map-002" },
      "role" => [ { "coding" => [ { "system" => SNOMED_SYSTEM, "code" => 446_050_000 } ] } ]
    )
    member = fetch_care_team_member(bundle)
    assert_equal "other", member.role_code
  end

  def test_fhir_adapter_maps_role_text_only_to_other
    bundle = care_team_bundle(
      "member" => { "reference" => "Practitioner/pr-map-003" },
      "role" => [ { "text" => "Primary care physician" } ]
    )
    member = fetch_care_team_member(bundle)
    assert_equal "other", member.role_code
  end

  def test_mock_adapter_round_trips_role_code
    @mock_adapter.add_care_team(
      "pt_mock_role",
      [ {
        practitioner_identifier: "pr_mock_role",
        role_code: "consultant",
        name: "SYNTHETIC TEAM",
        status: "active"
      } ]
    )
    member = @mock_adapter.get_care_team("pt_mock_role").sole
    assert_equal "consultant", member.role_code
    refute_respond_to member, :role
  end

  private

  def fetch_care_team_member(bundle)
    @fhir_adapter.stub(:fhir_search, bundle) do
      @fhir_adapter.get_care_team("pt-map-001").sole
    end
  end

  def participant_role_coding(system:, code:, display: nil)
    coding = { "system" => system, "code" => code }
    coding["display"] = display if display
    {
      "member" => { "reference" => "Practitioner/pr-map-001" },
      "role" => [ { "coding" => [ coding ] } ]
    }
  end

  def care_team_bundle(participant)
    {
      "resourceType" => "Bundle",
      "type" => "searchset",
      "entry" => [ {
        "resource" => {
          "resourceType" => "CareTeam",
          "id" => "ct_role_map",
          "status" => "active",
          "name" => "SYNTHETIC TEAM",
          "participant" => [ participant ]
        }
      } ]
    }
  end
end
