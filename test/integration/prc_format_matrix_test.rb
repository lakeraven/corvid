# frozen_string_literal: true

require "test_helper"

# Contract test for the PRC export fixture matrix under
# test/fixtures/overpayment_recovery/formats/.
#
# Each fixture models a real-world PRC export variant. This file enforces the
# parser/importer contract documented in FORMAT_MATRIX.md so future changes
# cannot silently break compatibility.
class Corvid::PrcFormatMatrixTest < ActiveSupport::TestCase
  FIXTURES_DIR = Rails.root.join("../fixtures/overpayment_recovery/formats")

  def fixture(name)
    FIXTURES_DIR.join(name).read
  end

  def with_matrix_tenant(name)
    with_tenant("tnt_fmt_#{name}") { yield }
  end

  test "standard_v1.prc imports baseline H/O/P/T report cleanly" do
    with_matrix_tenant(:standard) do
      result = Corvid::PrcImporter.import(
        fixture("standard_v1.prc"),
        source_file: "standard_v1.prc"
      )

      assert_equal 2, result[:obligations_imported]
      assert_equal 2, result[:obligations_inserted]
      assert_equal 3, result[:payments_imported]
      assert_equal :ok, result[:trailer_check]
      assert_equal 0, result[:sub_cent_truncations]

      assert_equal 2, Corvid::PrcObligation.count
      assert_equal 3, Corvid::PrcPayment.count

      hip = Corvid::PrcObligation.find_by(obligation_id: "OBL-FMT-1001")
      assert_equal Money.from_amount(42_000, "USD"), hip.paid_amount
      assert_equal 2, hip.prc_payments.count
    end
  end

  test "extended_fields_v1.prc ignores trailing fields on every record type" do
    with_matrix_tenant(:extended) do
      result = Corvid::PrcImporter.import(
        fixture("extended_fields_v1.prc"),
        source_file: "extended_fields_v1.prc"
      )

      assert_equal 2, result[:obligations_imported]
      assert_equal 2, result[:payments_imported]
      assert_equal :ok, result[:trailer_check]

      ob = Corvid::PrcObligation.find_by(obligation_id: "OBL-FMT-2001")
      assert_equal Money.from_amount(180, "USD"), ob.paid_amount

      pmt = Corvid::PrcPayment.find_by(payment_id: "PMT-FMT-2001")
      assert_equal "CHKEXT001", pmt.check_number
    end
  end

  test "payment_before_obligation_v1.prc reconciles payment that arrives before its obligation" do
    with_matrix_tenant(:payment_before_obligation) do
      result = Corvid::PrcImporter.import(
        fixture("payment_before_obligation_v1.prc"),
        source_file: "payment_before_obligation_v1.prc"
      )

      assert_equal 1, result[:obligations_imported]
      assert_equal 2, result[:payments_imported]
      assert_equal 0, result[:payments_dropped_orphan]
      assert_equal :ok, result[:trailer_check]

      obligation = Corvid::PrcObligation.find_by(obligation_id: "OBL-FMT-3001")
      assert_equal 2, obligation.prc_payments.count
      assert_equal [ "PMT-FMT-3001", "PMT-FMT-3002" ],
                   obligation.prc_payments.order(:payment_id).pluck(:payment_id)
    end
  end

  test "no_trailer_v1.prc imports without trailer and reports :missing trailer_check" do
    with_matrix_tenant(:no_trailer) do
      result = nil
      logs = capture_warns do
        result = Corvid::PrcImporter.import(
          fixture("no_trailer_v1.prc"),
          source_file: "no_trailer_v1.prc"
        )
      end

      assert_equal 2, result[:obligations_imported]
      assert_equal 2, result[:payments_imported]
      assert_equal :missing, result[:trailer_check]
      assert_match(/trailer.*missing/i, logs)
    end
  end

  test "invalid_dates_v1.prc degrades malformed dates to nil and still imports" do
    with_matrix_tenant(:invalid_dates) do
      result = Corvid::PrcImporter.import(
        fixture("invalid_dates_v1.prc"),
        source_file: "invalid_dates_v1.prc"
      )

      assert_equal 2, result[:obligations_imported]
      assert_equal 2, result[:payments_imported]

      header_only = Corvid::PrcReportParser.parse(fixture("invalid_dates_v1.prc"))
      assert_nil header_only.header.export_date

      bad_obligation = header_only.obligations.find { |o| o.obligation_id == "OBL-FMT-5001" }
      assert_nil bad_obligation.service_date

      bad_payment = header_only.payments.find { |p| p.payment_id == "PMT-FMT-5001" }
      assert_nil bad_payment.paid_date
    end
  end

  test "alternate_header_type_v2.prc tolerates different header type/version tokens" do
    with_matrix_tenant(:alternate_header) do
      result = Corvid::PrcImporter.import(
        fixture("alternate_header_type_v2.prc"),
        source_file: "alternate_header_type_v2.prc"
      )

      assert_equal 2, result[:obligations_imported]
      assert_equal 2, result[:payments_imported]
      assert_equal :ok, result[:trailer_check]

      report = Corvid::PrcReportParser.parse(fixture("alternate_header_type_v2.prc"))
      assert_equal "PRC-EXPORT-V2", report.header.type
      assert_equal "YAK", report.header.facility
      assert_equal "2", report.header.version
    end
  end

  test "malformed_no_header.prc fails closed with MalformedExportError" do
    with_matrix_tenant(:malformed_no_header) do
      assert_raises(Corvid::PrcImporter::MalformedExportError) do
        Corvid::PrcImporter.import(
          fixture("malformed_no_header.prc"),
          source_file: "malformed_no_header.prc"
        )
      end

      assert_equal 0, Corvid::PrcObligation.count,
                   "no rows persisted when the file is malformed"
      assert_equal 0, Corvid::PrcPayment.count
    end
  end

  test "duplicate_ids_v1.prc deduplicates last record wins for obligations and payments" do
    with_matrix_tenant(:duplicate_ids) do
      result = Corvid::PrcImporter.import(
        fixture("duplicate_ids_v1.prc"),
        source_file: "duplicate_ids_v1.prc"
      )

      assert_equal 2, result[:obligations_imported]
      assert_equal 1, result[:obligations_inserted]
      assert_equal 2, result[:payments_parsed]
      assert_equal 1, result[:payments_imported]
      assert_equal :ok, result[:trailer_check]

      obligation = Corvid::PrcObligation.find_by(obligation_id: "OBL-FMT-8001")
      assert_equal Money.from_amount(200, "USD"), obligation.paid_amount
      assert_equal Money.from_amount(200, "USD"), obligation.billed_amount

      payment = Corvid::PrcPayment.find_by(payment_id: "PMT-FMT-8001")
      assert_equal "CHKDUP002", payment.check_number
      assert_equal Money.from_amount(200, "USD"), payment.amount
    end
  end

  test "amount_precision_extremes_v1.prc truncates sub-cent values and imports extremes" do
    with_matrix_tenant(:amount_precision) do
      result = Corvid::PrcImporter.import(
        fixture("amount_precision_extremes_v1.prc"),
        source_file: "amount_precision_extremes_v1.prc"
      )

      assert_equal 3, result[:obligations_imported]
      assert_equal 3, result[:payments_imported]
      assert_operator result[:sub_cent_truncations], :>, 0,
                      "sub-cent precision fields must be counted"

      extreme = Corvid::PrcObligation.find_by(obligation_id: "OBL-FMT-9002")
      assert_equal Money.from_amount(999_999_999.99, "USD"), extreme.paid_amount

      penny = Corvid::PrcObligation.find_by(obligation_id: "OBL-FMT-9003")
      assert_equal Money.from_amount(0.01, "USD"), penny.paid_amount
    end
  end

  private

  # Capture Rails.logger.warn output for the duration of the block.
  def capture_warns
    captured = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(captured)
    Rails.logger.level = ::Logger::WARN
    yield
    captured.string
  ensure
    Rails.logger = original_logger if original_logger
  end
end
