# frozen_string_literal: true

require "test_helper"

class Corvid::PrcImporterTest < ActiveSupport::TestCase
  TENANT = "tnt_prc_test"

  SAMPLE = <<~PRC
    H^PRC_EXPORT^SEA^20090506^1
    O^OBL-2009-000123^DFN000456^VEND00987^HIP_REPLACE_THR^20090504^A^65000.00^42000.00^23000.00^0.00^2009
    P^OBL-2009-000123^PMT-2009-000001^20090615^CHK2009A^25000.00^SEA_HOSPITAL
    P^OBL-2009-000123^PMT-2009-000002^20090701^CHK2009B^17000.00^SEA_HOSPITAL
    O^OBL-2009-000124^DFN000789^VEND00211^OFFICE_VISIT_EST^20090510^A^200.00^180.00^20.00^0.00^2009
    P^OBL-2009-000124^PMT-2009-000003^20090620^CHK2009C^180.00^FAMILY_CLINIC
    T^2^2^3^42180.00^0.00
  PRC

  # -- Basic ingestion -------------------------------------------------------

  test "imports obligations from a PRC export string" do
    with_tenant(TENANT) do
      result = Corvid::PrcImporter.import(SAMPLE, source_file: "test_export.prc")

      assert_equal 2, result[:obligations_imported]
      assert_equal 3, result[:payments_imported]
      assert_equal 2, Corvid::PrcObligation.count
      assert_equal 3, Corvid::PrcPayment.count
    end
  end

  test "obligation rows carry source-file provenance" do
    with_tenant(TENANT) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test_export.prc")

      obligation = Corvid::PrcObligation.find_by(obligation_id: "OBL-2009-000123")
      assert_equal "test_export.prc", obligation.source_file
      refute_nil obligation.imported_at
      assert_equal "SEA", obligation.facility_identifier
    end
  end

  test "payments are linked to their obligations" do
    with_tenant(TENANT) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")

      obligation = Corvid::PrcObligation.find_by(obligation_id: "OBL-2009-000123")
      assert_equal 2, obligation.prc_payments.count
      assert_equal [ "PMT-2009-000001", "PMT-2009-000002" ],
                   obligation.prc_payments.order(:payment_id).pluck(:payment_id)
    end
  end

  # -- Malformed input -------------------------------------------------------

  test "raises MalformedExportError when the file has no header" do
    no_header = "T^0^0^0^0.00^0.00\n"
    with_tenant(TENANT) do
      assert_raises(Corvid::PrcImporter::MalformedExportError) do
        Corvid::PrcImporter.import(no_header, source_file: "broken.prc")
      end
      assert_equal 0, Corvid::PrcObligation.count,
                   "no rows persisted when the file is malformed"
    end
  end

  test "raises MissingTenantContextError when no tenant is set" do
    assert_raises(Corvid::MissingTenantContextError) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")
    end
  end

  # -- Idempotency -----------------------------------------------------------

  test "re-importing the same file does not duplicate rows" do
    with_tenant(TENANT) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")
      assert_equal 2, Corvid::PrcObligation.count
      assert_equal 3, Corvid::PrcPayment.count

      result = Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")

      assert_equal 2, Corvid::PrcObligation.count, "no duplicate obligations"
      assert_equal 3, Corvid::PrcPayment.count, "no duplicate payments"
      assert_equal 2, result[:obligations_imported]
      assert_equal 0, result[:obligations_inserted],
                   "second import inserts zero new obligations"
    end
  end

  test "updating an obligation between imports refreshes its fields" do
    with_tenant(TENANT) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")
      original_paid = Corvid::PrcObligation.find_by(obligation_id: "OBL-2009-000123").paid_amount
      assert_equal 42_000.to_d, original_paid

      # Same obligation_id but paid amount has been corrected to a new value
      updated = SAMPLE.sub("42000.00", "45000.00")
      Corvid::PrcImporter.import(updated, source_file: "test_corrected.prc")

      reloaded = Corvid::PrcObligation.find_by(obligation_id: "OBL-2009-000123")
      assert_equal 45_000.to_d, reloaded.paid_amount,
                   "obligation row reflects the latest export's values"
      assert_equal "test_corrected.prc", reloaded.source_file,
                   "source_file updates to the most recent import"
    end
  end

  # -- Tenant scoping --------------------------------------------------------

  test "obligations are tenant-scoped" do
    with_tenant(TENANT) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")
    end
    other_tenant = "tnt_other"
    with_tenant(other_tenant) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")
    end

    with_tenant(TENANT) do
      assert_equal 2, Corvid::PrcObligation.count
    end
    with_tenant(other_tenant) do
      assert_equal 2, Corvid::PrcObligation.count
    end
    assert_equal 4, Corvid::PrcObligation.unscoped.count
  end

  # -- Reanalysis ------------------------------------------------------------

  test "reanalyze runs the analyzer over imported obligations and persists results" do
    with_tenant(TENANT) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")
      seed_pfs_for_office_visit

      result = Corvid::PrcImporter.reanalyze(tenant: TENANT)

      assert_equal 2, result[:analyses_written]
      assert_equal 2, Corvid::PrcOverpaymentAnalysis.count
    end
  end

  test "reanalyze preserves prior analysis history (does not delete)" do
    with_tenant(TENANT) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")
      seed_pfs_for_office_visit

      Corvid::PrcImporter.reanalyze(tenant: TENANT)
      assert_equal 2, Corvid::PrcOverpaymentAnalysis.count

      # Second pass — preserves history rather than overwriting
      Corvid::PrcImporter.reanalyze(tenant: TENANT)
      assert_equal 4, Corvid::PrcOverpaymentAnalysis.count,
                   "each reanalysis appends rows; older ones remain for audit"
    end
  end

  test "reanalysis rows carry payment_system, recovery_confidence, and rate_source" do
    with_tenant(TENANT) do
      Corvid::PrcImporter.import(SAMPLE, source_file: "test.prc")
      seed_pfs_for_office_visit
      Corvid::PrcImporter.reanalyze(tenant: TENANT)

      hip_obligation = Corvid::PrcObligation.find_by(obligation_id: "OBL-2009-000123")
      hip_analysis = hip_obligation.latest_analysis
      assert_equal "ipps", hip_analysis.payment_system
      assert_equal "stub_estimate", hip_analysis.recovery_confidence
      assert_equal "stub", hip_analysis.rate_source
      assert hip_analysis.overpayment.positive?

      office_obligation = Corvid::PrcObligation.find_by(obligation_id: "OBL-2009-000124")
      office_analysis = office_obligation.latest_analysis
      assert_equal "pfs", office_analysis.payment_system
      assert_equal "clear", office_analysis.recovery_confidence
      assert_equal "real", office_analysis.rate_source
    end
  end

  private

  def seed_pfs_for_office_visit
    Corvid::FeeScheduleEntry.create!(
      cpt_code: "99213",
      locality: "02",
      effective_date: Date.new(2009, 5, 4),
      work_rvu: 0.92, pe_rvu: 0.74, mp_rvu: 0.07,
      work_gpci: 1.014, pe_gpci: 1.085, mp_gpci: 0.706,
      conversion_factor: 36.0666
    )
  end
end
