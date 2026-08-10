# frozen_string_literal: true

require "test_helper"

class Corvid::ExemptionAttestationServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_att_test"

  setup do
    Corvid::TenantContext.current_tenant_identifier = TENANT
    @adapter = Corvid.adapter
    @adapter.add_ai_an_status("pt_att", ai_an: true, ihs_beneficiary: true,
                              basis: "ai_an_ihs_beneficiary", confidence: :verified)
  end

  test "generates an attestation from a person's in-effect exemptions" do
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_att", asserted_by_identifier: "usr_1")

    attestation = Corvid::ExemptionAttestationService.generate(person_identifier: "pt_att")

    assert_equal "pt_att", attestation[:person_identifier]
    assert_match(/HR-1/, attestation[:statutory_basis])
    assert_equal 2, attestation[:exemptions].size

    line = attestation[:exemptions].find { |l| l[:exemption_type] == "work_requirement" }
    assert_equal "Medicaid community-engagement / work requirement", line[:exemption_label]
    assert_equal "Corvid::Adapters::MockAdapter", line[:verification][:source]
    assert_equal "verified", line[:verification][:confidence]
    refute_nil line[:verification][:snapshot_hash]
  end

  test "generates from a single exemption instance" do
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_att", exemption_types: [ "work_requirement" ])
    exemption = Corvid::MedicaidExemption.for_person("pt_att").active.first

    attestation = Corvid::ExemptionAttestationService.generate(exemption: exemption)
    assert_equal 1, attestation[:exemptions].size
  end

  test "raises when there is no in-effect exemption to attest" do
    assert_raises(ArgumentError) do
      Corvid::ExemptionAttestationService.generate(person_identifier: "pt_none")
    end
  end

  test "a future-effective exemption is not surfaced in an attestation" do
    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_att", exemption_types: [ "work_requirement" ],
      effective_date: 1.day.from_now.to_date
    )

    assert_raises(ArgumentError) do
      Corvid::ExemptionAttestationService.generate(person_identifier: "pt_att")
    end
  end

  test "rejects an exemption record from another tenant" do
    other = nil
    with_tenant("tnt_other_att") do
      @adapter.add_ai_an_status("pt_o", ai_an: true, confidence: :verified)
      Corvid::MedicaidExemptionService.assert(person_identifier: "pt_o", exemption_types: [ "work_requirement" ])
      other = Corvid::MedicaidExemption.for_person("pt_o").active.first
    end

    assert_raises(ArgumentError) do
      Corvid::ExemptionAttestationService.generate(exemption: other)
    end
  end

  test "rejects an array of exemptions spanning more than one person" do
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_att", exemption_types: [ "work_requirement" ])
    a = Corvid::MedicaidExemption.for_person("pt_att").active.first

    @adapter.add_ai_an_status("pt_att2", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_att2", exemption_types: [ "work_requirement" ])
    b = Corvid::MedicaidExemption.for_person("pt_att2").active.first

    assert_raises(ArgumentError) do
      Corvid::ExemptionAttestationService.generate(exemption: [ a, b ])
    end
  end
end
