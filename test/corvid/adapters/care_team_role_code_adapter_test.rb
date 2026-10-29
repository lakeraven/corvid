# frozen_string_literal: true

require "test_helper"

class Corvid::CareTeamRoleCodeAdapterTest < ActiveSupport::TestCase
  SNOMED_SYSTEM = "http://snomed.info/sct"
  SNOMED_PCP_CODE = "446050000"
  ENGINE_ROLE_SYSTEM = Corvid::CareTeam::FHIR_ROLE_SYSTEM
  ENGINE_ROLE_CODES = %w[
    primary_care_provider
    care_manager
    consultant
    other
  ].freeze
  FOREIGN_ROLE_SYSTEM = "http://example.test/roles"

  setup do
    @fhir_adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://example.test/fhir")
    @mock_adapter = Corvid::Adapters::MockAdapter.new
    Corvid::TenantContext.current_tenant_identifier = "tnt_ct_adapter_role"
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
      participant_role_coding(system: FOREIGN_ROLE_SYSTEM, code: SNOMED_PCP_CODE)
    )
    member = fetch_care_team_member(bundle)
    assert_equal "other", member.role_code
  end

  ENGINE_ROLE_CODES.each do |engine_code|
    define_method("test_fhir_adapter_maps_engine_role_system_#{engine_code}_to_same_code") do
      bundle = care_team_bundle(
        participant_role_coding(system: ENGINE_ROLE_SYSTEM, code: engine_code)
      )
      member = fetch_care_team_member(bundle)
      assert_equal engine_code, member.role_code
    end
  end

  def test_fhir_adapter_maps_unknown_code_under_engine_role_system_to_other
    bundle = care_team_bundle(
      participant_role_coding(system: ENGINE_ROLE_SYSTEM, code: "care_coordinator")
    )
    member = fetch_care_team_member(bundle)
    assert_equal "other", member.role_code
  end

  %w[consultant care_manager primary_care_provider].each do |engine_shaped_code|
    define_method("test_fhir_adapter_does_not_passthrough_#{engine_shaped_code}_from_foreign_system") do
      bundle = care_team_bundle(
        participant_role_coding(system: FOREIGN_ROLE_SYSTEM, code: engine_shaped_code)
      )
      member = fetch_care_team_member(bundle)
      assert_equal "other", member.role_code
    end

    define_method("test_fhir_adapter_does_not_passthrough_#{engine_shaped_code}_from_snomed") do
      bundle = care_team_bundle(
        participant_role_coding(system: SNOMED_SYSTEM, code: engine_shaped_code)
      )
      member = fetch_care_team_member(bundle)
      assert_equal "other", member.role_code
    end
  end

  def test_fhir_adapter_round_trips_care_team_to_fhir_participant_roles
    team = Corvid::CareTeam.create!(name: "Adapter round trip", facility_identifier: "fac_ct_adapter")
    practitioners = {
      "primary_care_provider" => "pr_01HK8B7Z9XCQVG3F8N5K0R4MWA",
      "care_manager" => "pr_01HK8B7Z9XCQVG3F8N5K0R4MWB",
      "consultant" => "pr_01HK8B7Z9XCQVG3F8N5K0R4MWC",
      "other" => "pr_01HK8B7Z9XCQVG3F8N5K0R4MWD"
    }
    practitioners.each do |role_code, practitioner_identifier|
      team.add_member!(role_code: role_code, practitioner_identifier: practitioner_identifier)
    end

    exported = JSON.parse(team.to_fhir.to_json)
    bundle = care_team_bundle_from_export(exported)

    members = @fhir_adapter.stub(:fhir_search, bundle) do
      @fhir_adapter.get_care_team("pt_rt_roundtrip")
    end

    assert_equal practitioners.size, members.size
    by_practitioner = members.index_by(&:practitioner_identifier)
    practitioners.each do |expected_role_code, practitioner_identifier|
      assert_equal expected_role_code, by_practitioner.fetch(practitioner_identifier).role_code
    end
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
    care_team_bundle_from_export(
      "participant" => [ participant ],
      "name" => "SYNTHETIC TEAM"
    )
  end

  def care_team_bundle_from_export(exported_care_team)
    {
      "resourceType" => "Bundle",
      "type" => "searchset",
      "entry" => [ {
        "resource" => {
          "resourceType" => "CareTeam",
          "id" => exported_care_team.fetch("id", "ct_role_map"),
          "status" => exported_care_team.fetch("status", "active"),
          "name" => exported_care_team.fetch("name", "SYNTHETIC TEAM"),
          "participant" => exported_care_team.fetch("participant")
        }
      } ]
    }
  end
end
