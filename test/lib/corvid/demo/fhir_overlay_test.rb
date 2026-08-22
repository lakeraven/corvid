# frozen_string_literal: true

require "test_helper"
require "stringio"
require "corvid/demo/fhir_overlay_demo"

# Red-first coverage for the stock-FHIR overlay demo (multi-clinic PRC + MLR).
#
# Asserts: generic stock-FHIR ingest creates Cases + obligations for BOTH
# synthetic clinics; MLR repricing yields the expected per-clinic savings from
# real CMS data; and the consortium total aggregates both clinics. Everything
# is synthetic.
class Corvid::Demo::FhirOverlayTest < ActiveSupport::TestCase
  Data = Corvid::Demo::FhirOverlayData
  Seed = Corvid::Demo::CmsRateSeed
  Ingest = Corvid::Demo::FhirOverlayIngest

  def adapter_for(clinic)
    Corvid::Adapters::FhirDemoAdapter.new(resources: clinic.resources)
  end

  def patient_ids(clinic)
    clinic.resources.select { |r| r["resourceType"] == "Patient" }.map { |r| r["id"] }
  end

  # Independently recompute expected MLR savings from the seeded real CMS
  # rate rows + the known synthetic billed charges — a genuine cross-check
  # of the analyzer, not a tautology.
  def expected_savings_for(clinic)
    clinic.resources.select { |r| r["resourceType"] == "Claim" }.sum do |claim|
      item = claim["item"].first
      code = item.dig("productOrService", "coding", 0, "code")
      billed = item.dig("net", "value")
      date = Date.parse(item["servicedDate"])
      mlr =
        if Seed::PFS_CODES.key?(code)
          Corvid::FeeScheduleEntry
            .rate_for(cpt_code: code, locality: Seed::MONTANA_LOCALITY, date: date)
            .medicare_rate.to_f.round(2)
        else
          apc = Seed::OPPS_CODES.fetch(code).first
          Corvid::OppsRateProvider.rate_for(apc_code: apc, locality: Seed::MONTANA_LOCALITY, date: date).to_f.round(2)
        end
      [ billed - mlr, 0 ].max.round(2)
    end.round(2)
  end

  test "stock-FHIR ingest creates Cases and obligations for BOTH synthetic clinics" do
    Data.clinics.each do |clinic|
      adapter = adapter_for(clinic)
      Corvid.configure { |c| c.adapter = adapter }

      with_tenant(clinic.tenant) do
        Corvid::TenantContext.current_facility_identifier = clinic.facility
        counts = Ingest.ingest(
          facility: clinic.facility,
          patient_identifiers: patient_ids(clinic),
          adapter: adapter
        )

        assert_equal 3, counts[:cases_created], "#{clinic.name}: one Case per patient"
        assert_equal 5, counts[:obligations_created], "#{clinic.name}: one obligation per claim line"
        assert_equal 3, Corvid::Case.for_facility(clinic.facility).count
        assert_equal 5, Corvid::PrcObligation.for_facility(clinic.facility).count

        # Case patient_identifier is the tokenized FHIR patient id (no PHI FK).
        assert_equal patient_ids(clinic).sort,
                     Corvid::Case.for_facility(clinic.facility).pluck(:patient_identifier).sort
      end
    end
  end

  test "MLR repricing yields expected per-clinic savings, all real/:clear" do
    Data.clinics.each do |clinic|
      Seed.seed! # real CMS rates + dictionaries (cleaned each test by setup)
      adapter = adapter_for(clinic)
      Corvid.configure { |c| c.adapter = adapter }

      with_tenant(clinic.tenant) do
        Corvid::TenantContext.current_facility_identifier = clinic.facility
        Ingest.ingest(facility: clinic.facility, patient_identifiers: patient_ids(clinic), adapter: adapter)
        summary = Ingest.analyze(facility: clinic.facility)

        assert_equal 5, summary.obligations_analyzed
        assert summary.total_overpayment_known > 0, "#{clinic.name}: should recover money"
        assert summary.results.all? { |r| r.recovery_confidence == :clear },
               "#{clinic.name}: every line priced from real CMS data"
        assert_in_delta expected_savings_for(clinic), summary.total_overpayment_known, 0.01,
                        "#{clinic.name}: analyzer savings match independent MLR recompute"
      end
    end
  end

  test "consortium total aggregates both clinics" do
    io = StringIO.new
    result = Corvid::Demo::FhirOverlayDemo.run(io: io)

    summaries = result[:clinics].map { |c| c[:summary] }
    assert_equal 2, summaries.size

    per_clinic_total = summaries.sum { |s| s.total_overpayment_known }.round(2)

    # Recompute the consortium total independently from each clinic's dataset.
    independent_total = Data.clinics.sum { |clinic| expected_savings_for_after_seed(clinic) }.round(2)

    assert_in_delta independent_total, per_clinic_total, 0.02,
                    "consortium recovered = clinic A + clinic B"
    assert per_clinic_total > 0

    output = io.string
    assert_match(/CONSORTIUM TOTAL/, output)
    assert_match(/TOTAL \$ RECOVERED/, output)
    assert_match(/CEHRT-SAFE OVERLAY/, output)
    assert_match(/Broken Rock Clinic/, output)
    assert_match(/Tallgrass Clinic/, output)
  end

  test "dataset is fully synthetic (no real clinic/place/vendor names)" do
    blob = Data.clinics.flat_map(&:resources).to_s.downcase
    labels = Data.clinics.map(&:source_ehr_label).join(" ").downcase
    forbidden = %w[osage pawhuska billings missoula mcuih buihwc greenway eclinicalworks]
    forbidden.each do |name|
      refute_includes blob, name, "synthetic dataset must not contain #{name}"
      refute_includes labels, name, "source EHR label must not name a real vendor (#{name})"
    end
    assert_equal [ "Broken Rock Clinic", "Tallgrass Clinic" ], Data.clinics.map(&:name)
  end

  test "ingest surfaces silently-skipped lines instead of dropping them" do
    patient = Data.patient("pt_skip_1", "OVERLAY", "PATIENT SKIP", "1980-01-01", "F", "SK-1")
    priceable = Data.claim("clm_ok", "pt_skip_1", "V1", "Vendor One",
                           "99213", "2026-02-10", 240.00, Data::CPT_SYSTEM, "Office visit")
    # A claim line whose net amount is absent: today it is silently dropped.
    missing_amt = Data.claim("clm_bad", "pt_skip_1", "V1", "Vendor One",
                             "99214", "2026-03-10", 300.00, Data::CPT_SYSTEM, "Office visit")
    missing_amt["item"].first.delete("net")

    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [ patient, priceable, missing_amt ])
    Corvid.configure { |c| c.adapter = adapter }

    with_tenant("tnt_skip") do
      Corvid::TenantContext.current_facility_identifier = "fac_skip"
      counts = Ingest.ingest(facility: "fac_skip", patient_identifiers: [ "pt_skip_1" ], adapter: adapter)

      assert_equal 1, counts[:obligations_created], "only the priceable line becomes an obligation"
      assert_equal 1, counts[:skipped], "the amount-less line is counted, not silently dropped"
      assert(counts[:skipped_reasons].any? { |s| s[:reason] =~ /amount/i },
             "the skipped line and its reason are visible in the returned counts")
    end
  end

  # After FhirOverlayDemo.run has seeded CMS rates, recompute a clinic's
  # expected savings (rates are still in the DB post-run).
  def expected_savings_for_after_seed(clinic)
    expected_savings_for(clinic)
  end
end
