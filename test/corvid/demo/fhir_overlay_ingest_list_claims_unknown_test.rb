# frozen_string_literal: true

require "test_helper"
require "corvid/demo/fhir_overlay_ingest"

class Corvid::Demo::FhirOverlayIngestListClaimsUnknownTest < ActiveSupport::TestCase
  Ingest = Corvid::Demo::FhirOverlayIngest

  test "ingest does not treat nil list_claims as zero obligations and reports claims unknown" do
    patient_ref = Corvid::PatientReference.new(
      identifier: "pt_test_001",
      display_name: "TEST,PATIENT 001",
      dob: Date.new(1980, 1, 1),
      sex: "F",
      ssn_last4: "0001"
    )
    adapter = Minitest::Mock.new
    adapter.expect(:find_patient, patient_ref, [ "pt_test_001" ])
    adapter.expect(:list_claims, nil, [ "pt_test_001" ])

    with_tenant("tnt_test") do
      Corvid::TenantContext.current_facility_identifier = "fac_test_674"

      counts = nil
      begin
        counts = Ingest.ingest(
          facility: "fac_test_674",
          patient_identifiers: [ "pt_test_001" ],
          adapter: adapter
        )
      rescue NoMethodError
        flunk "ingest must handle nil list_claims without NoMethodError (fail closed, no partial writes)"
      end

      assert_equal 0, Corvid::PrcObligation.for_facility("fac_test_674").count,
                   "must not write obligations when claims are unknown"
      assert_equal 0, counts[:obligations_created]
      assert_equal [ "pt_test_001" ], counts[:patients_claims_unknown],
                   "patient with unknown claims must be reported, not silently ingested as empty"
      refute Corvid::Case.exists?(patient_identifier: "pt_test_001", facility_identifier: "fac_test_674"),
             "must not persist a Case when claims could not be read (no partial ingest)"
    end

    adapter.verify
  end
end
