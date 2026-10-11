# frozen_string_literal: true

require "test_helper"

# H.R. 1 community-engagement exemption for American Indian / Alaska Native
# individuals. The service gathers evidence from one or more sources (state
# claims, tribal enrollment, clinic records) and reports whether AI/AN status
# is established, on what basis, and from which source.
#
# Absence of evidence is never a finding of "not AI/AN": the outcome is
# :not_established, and the caller falls back to attestation or documents.
class Corvid::AianExemptionServiceTest < ActiveSupport::TestCase
  TENANT = "tenant_test"
  AS_OF = Date.new(2027, 3, 1)

  setup do
    Corvid::TenantContext.reset!
    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
    Corvid::AianExemptionDetermination.unscoped.delete_all
    @adapter = Corvid.adapter
  end

  teardown do
    Corvid::TenantContext.reset!
  end

  def determine(person, **opts)
    with_tenant(TENANT) do
      Corvid::AianExemptionService.new(**opts.slice(:sources))
        .determine(person_identifier: person, as_of_date: AS_OF, **opts.except(:sources))
    end
  end

  def determination(id)
    with_tenant(TENANT) { Corvid::AianExemptionDetermination.find(id) }
  end

  # ---- Each basis establishes the exemption -----------------------------------

  test "an enrolled tribal member is exempt on the enrolled_tribal_member basis" do
    @adapter.add_enrollment("pt_member", enrolled: true, tribe_code: "DEMO", confidence: :verified)

    result = determine("pt_member")

    assert_equal :exempt, result.status
    assert result.exempt?
    assert_equal [ :enrolled_tribal_member ], result.bases
  end

  test "a child or grandchild of an enrolled member is exempt on the descendant basis" do
    @adapter.add_tribal_descent("pt_desc", descendant: true, relationship: :grandparent,
                                           tribe_code: "DEMO", confidence: :verified)

    result = determine("pt_desc")

    assert_equal :exempt, result.status
    assert_equal [ :descendant_of_enrolled_member ], result.bases
  end

  test "an Alaska Native Corporation shareholder is exempt" do
    @adapter.add_anc_shareholder("pt_anc", shareholder: true, corporation_code: "ANC_DEMO", confidence: :verified)

    result = determine("pt_anc")

    assert_equal :exempt, result.status
    assert_equal [ :alaska_native_corporation_shareholder ], result.bases
  end

  test "a person who received care at an IHS, tribal or urban Indian site is exempt" do
    @adapter.add_itu_encounter("pt_itu", service_date: Date.new(2026, 11, 4), facility_kind: :tribal)

    result = determine("pt_itu")

    assert_equal :exempt, result.status
    assert_equal [ :received_itu_services ], result.bases
  end

  test "every basis found is reported, in a stable order" do
    @adapter.add_itu_encounter("pt_multi", service_date: Date.new(2026, 6, 1), facility_kind: :ihs)
    @adapter.add_enrollment("pt_multi", enrolled: true, tribe_code: "DEMO", confidence: :verified)

    result = determine("pt_multi")

    assert_equal %i[enrolled_tribal_member received_itu_services], result.bases
  end

  # ---- Absence of evidence is not a negative finding --------------------------

  test "no evidence from any source yields :not_established, never a denial" do
    result = determine("pt_unknown")

    assert_equal :not_established, result.status
    refute result.exempt?
    assert_empty result.bases
  end

  test "an encounter after the as-of date does not count" do
    @adapter.add_itu_encounter("pt_future", service_date: AS_OF + 1, facility_kind: :urban)

    assert_equal :not_established, determine("pt_future").status
  end

  test "an encounter older than a state's lookback window does not count" do
    @adapter.add_itu_encounter("pt_old", service_date: AS_OF - 400, facility_kind: :ihs)

    assert_equal :exempt, determine("pt_old").status
    assert_equal :not_established, determine("pt_old", itu_lookback_days: 365).status
  end

  # ---- Source availability ------------------------------------------------------

  test "every source unreachable yields :unavailable so the caller can retry" do
    @adapter.define_singleton_method(:verify_tribal_enrollment) { |_| { enrolled: false, confidence: :unavailable } }
    @adapter.define_singleton_method(:verify_tribal_descent) { |_| { descendant: false, confidence: :unavailable } }
    @adapter.define_singleton_method(:verify_alaska_native_corporation_shareholder) { |_| { shareholder: false, confidence: :unavailable } }
    @adapter.define_singleton_method(:list_itu_encounters) { |_, **| { encounters: [], confidence: :unavailable } }

    assert_equal :unavailable, determine("pt_down").status
  end

  test "a source that does not implement a check is skipped, not treated as a failure" do
    claims_only = Object.new
    claims_only.define_singleton_method(:list_itu_encounters) do |_, **|
      { encounters: [ { service_date: Date.new(2026, 9, 9), facility_kind: :tribal } ], confidence: :verified }
    end

    result = determine("pt_claims", sources: [ claims_only ])

    assert_equal :exempt, result.status
    assert_equal [ :received_itu_services ], result.bases
  end

  test "a later source supplies evidence an earlier source lacked" do
    state_claims = Object.new
    state_claims.define_singleton_method(:list_itu_encounters) { |_, **| { encounters: [], confidence: :verified } }
    @adapter.add_enrollment("pt_tribe", enrolled: true, tribe_code: "DEMO", confidence: :verified)

    result = determine("pt_tribe", sources: [ state_claims, @adapter ])

    assert_equal :exempt, result.status
    assert_equal [ :enrolled_tribal_member ], result.bases
  end

  test "stale evidence still establishes the exemption but is flagged" do
    @adapter.add_enrollment("pt_stale", enrolled: true, tribe_code: "DEMO", confidence: :stale)

    result = determine("pt_stale")

    assert_equal :exempt, result.status
    assert_includes result.warnings, :evidence_stale
  end

  # ---- Audit record -------------------------------------------------------------

  test "every determination writes one audit row with bases and sources but no PHI" do
    @adapter.add_enrollment("pt_audit", enrolled: true, tribe_code: "DEMO",
                                        membership_number: "MOCK-0001", confidence: :verified)

    result = determine("pt_audit", decided_by_identifier: "user_42")

    row = determination(result.determination_id)
    assert_equal "exempt", row.status
    assert_equal [ "enrolled_tribal_member" ], row.bases
    assert_equal "user_42", row.decided_by_identifier
    assert_equal AS_OF, row.as_of_date
    assert_equal [ "Corvid::Adapters::MockAdapter" ], row.evidence.map { |e| e["source"] }.uniq
    refute_includes row.evidence.to_json, "MOCK-0001"
    assert_match(/\A\h{64}\z/, row.verification_snapshot_hash)
  end

  test "class-method shim routes through the global adapter" do
    @adapter.add_enrollment("pt_shim", enrolled: true, tribe_code: "DEMO", confidence: :verified)

    result = with_tenant(TENANT) do
      Corvid::AianExemptionService.determine(person_identifier: "pt_shim", as_of_date: AS_OF)
    end

    assert_equal :exempt, result.status
  end

  # ---- FHIR output ----------------------------------------------------------------

  test "a determination renders as a FHIR R4 VerificationResult" do
    @adapter.add_enrollment("pt_fhir", enrolled: true, tribe_code: "DEMO", confidence: :verified)

    result = determine("pt_fhir")
    fhir = determination(result.determination_id).to_fhir_verification_result

    assert_equal "VerificationResult", fhir[:resourceType]
    assert_equal "validated", fhir[:status]
    assert_equal "Patient/pt_fhir", fhir[:target].first[:reference]
    assert_includes fhir[:targetLocation], "Patient.extension:aianExemption"
    assert_equal "enrolled_tribal_member", fhir[:primarySource].first[:type].first[:coding].first[:code]
  end

  test "an unestablished determination renders as an in-process VerificationResult, not a failure" do
    result = determine("pt_none")
    fhir = determination(result.determination_id).to_fhir_verification_result

    assert_equal "in-process", fhir[:status]
    assert_empty fhir[:primarySource]
  end
end
