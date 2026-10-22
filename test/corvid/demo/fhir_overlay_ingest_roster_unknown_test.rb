# frozen_string_literal: true

require "test_helper"
require "corvid/demo/fhir_overlay_ingest"

class Corvid::Demo::FhirOverlayIngestRosterUnknownTest < ActiveSupport::TestCase
  Ingest = Corvid::Demo::FhirOverlayIngest

  def patient_ref(id)
    Corvid::PatientReference.new(
      identifier: id,
      display_name: "TEST,PATIENT #{id}",
      dob: Date.new(1980, 1, 1),
      sex: "F",
      ssn_last4: "0001"
    )
  end

  def claim_line(id)
    Corvid::ClaimLineReference.new(
      claim_identifier: "c_#{id}",
      patient_identifier: id,
      provider_identifier: "vend_test_001",
      procedure_code: "99213",
      procedure_display: nil,
      serviced_date: Date.new(2026, 1, 2),
      billed_amount: BigDecimal("100.00"),
      amount_error: nil,
      currency: "USD",
      sequence: 1
    )
  end

  test "ingest is all-or-nothing when any roster patient has unknown claims" do
    adapter = Minitest::Mock.new
    adapter.expect(:find_patient, patient_ref("pt_test_001"), [ "pt_test_001" ])
    adapter.expect(:list_claims, [ claim_line("pt_test_001") ], [ "pt_test_001" ])
    adapter.expect(:find_patient, patient_ref("pt_test_002"), [ "pt_test_002" ])
    adapter.expect(:list_claims, nil, [ "pt_test_002" ])

    with_tenant("tnt_test") do
      Corvid::TenantContext.current_facility_identifier = "fac_ingest_674"

      counts = Ingest.ingest(
        facility: "fac_ingest_674",
        patient_identifiers: %w[pt_test_001 pt_test_002],
        adapter: adapter
      )

      assert_equal [ "pt_test_002" ], counts[:patients_claims_unknown]
      assert_equal 0, counts[:cases_created]
      assert_equal 0, counts[:obligations_created]
      assert_equal 0, Corvid::Case.for_facility("fac_ingest_674").count
      assert_equal 0, Corvid::PrcObligation.for_facility("fac_ingest_674").count
      refute Corvid::Case.exists?(patient_identifier: "pt_test_001", facility_identifier: "fac_ingest_674")
    end

    adapter.verify
  end

  test "ingest is all-or-nothing when find_patient is unknown for a roster patient" do
    adapter = Minitest::Mock.new
    adapter.expect(:find_patient, patient_ref("pt_test_001"), [ "pt_test_001" ])
    adapter.expect(:list_claims, [ claim_line("pt_test_001") ], [ "pt_test_001" ])
    adapter.expect(:find_patient, nil, [ "pt_test_003" ])

    with_tenant("tnt_test") do
      Corvid::TenantContext.current_facility_identifier = "fac_ingest_674"

      counts = Ingest.ingest(
        facility: "fac_ingest_674",
        patient_identifiers: %w[pt_test_001 pt_test_003],
        adapter: adapter
      )

      assert_equal [ "pt_test_003" ], counts[:patients_unknown]
      assert_equal 0, counts[:cases_created]
      assert_equal 0, counts[:obligations_created]
      assert_equal 0, Corvid::Case.for_facility("fac_ingest_674").count
      assert_equal 0, Corvid::PrcObligation.for_facility("fac_ingest_674").count
    end

    adapter.verify
  end

  test "ingest leaves nothing persisted when adapter raises mid-roster" do
    build_ref = ->(id) { patient_ref(id) }
    build_line = ->(id) { claim_line(id) }
    adapter = Object.new
    adapter.define_singleton_method(:find_patient) { |id| build_ref.call(id) }
    adapter.define_singleton_method(:list_claims) do |id|
      raise RuntimeError, "synthetic adapter fault" if id == "pt_test_002"

      [ build_line.call(id) ]
    end

    with_tenant("tnt_test") do
      Corvid::TenantContext.current_facility_identifier = "fac_ingest_674"

      assert_raises(RuntimeError) do
        Ingest.ingest(
          facility: "fac_ingest_674",
          patient_identifiers: %w[pt_test_001 pt_test_002],
          adapter: adapter
        )
      end

      assert_equal 0, Corvid::Case.for_facility("fac_ingest_674").count
      assert_equal 0, Corvid::PrcObligation.for_facility("fac_ingest_674").count
    end
  end

  test "ingest unchanged for fully answered multi-patient roster" do
    adapter = Minitest::Mock.new
    %w[pt_test_001 pt_test_002].each do |id|
      adapter.expect(:find_patient, patient_ref(id), [ id ])
      adapter.expect(:list_claims, [ claim_line(id) ], [ id ])
    end

    with_tenant("tnt_test") do
      Corvid::TenantContext.current_facility_identifier = "fac_ingest_674"

      counts = Ingest.ingest(
        facility: "fac_ingest_674",
        patient_identifiers: %w[pt_test_001 pt_test_002],
        adapter: adapter
      )

      assert_equal [], counts[:patients_claims_unknown]
      assert_equal [], counts.fetch(:patients_unknown, [])
      assert_equal 2, counts[:cases_created]
      assert_equal 2, counts[:obligations_created]
      assert_equal 2, Corvid::Case.for_facility("fac_ingest_674").count
      assert_equal 2, Corvid::PrcObligation.for_facility("fac_ingest_674").count
    end

    adapter.verify
  end
end
