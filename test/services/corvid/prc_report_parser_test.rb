# frozen_string_literal: true

require "test_helper"

class Corvid::PrcReportParserTest < ActiveSupport::TestCase
  SAMPLE = <<~PRC
    H^PRC_EXPORT^SEA^20090506^1
    O^OBL-2009-000123^DFN000456^VEND00987^HIP_REPLACE_THR^20090504^A^65000.00^42000.00^23000.00^0.00^2009
    P^OBL-2009-000123^PMT-2009-000001^20090615^CHK2009A^25000.00^SEA_HOSPITAL
    P^OBL-2009-000123^PMT-2009-000002^20090701^CHK2009B^17000.00^SEA_HOSPITAL
    T^1^1^2^42000.00^0.00
  PRC

  test "parses the header record" do
    report = Corvid::PrcReportParser.parse(SAMPLE)

    assert_equal "PRC_EXPORT", report.header.type
    assert_equal "SEA", report.header.facility
    assert_equal Date.new(2009, 5, 6), report.header.export_date
    assert_equal "1", report.header.version
  end

  test "parses obligation records" do
    report = Corvid::PrcReportParser.parse(SAMPLE)

    assert_equal 1, report.obligations.size
    obligation = report.obligations.first

    assert_equal "OBL-2009-000123", obligation.obligation_id
    assert_equal "DFN000456", obligation.patient_dfn
    assert_equal "VEND00987", obligation.vendor_id
    assert_equal "HIP_REPLACE_THR", obligation.procedure_code
    assert_equal Date.new(2009, 5, 4), obligation.service_date
    assert_equal "A", obligation.status
    assert_equal 65000.00.to_d, obligation.billed_amount
    assert_equal 42000.00.to_d, obligation.paid_amount
    assert_equal 23000.00.to_d, obligation.savings
    assert_equal 0.00.to_d, obligation.balance
    assert_equal 2009, obligation.fiscal_year
  end

  test "parses payment records" do
    report = Corvid::PrcReportParser.parse(SAMPLE)

    assert_equal 2, report.payments.size

    first_payment = report.payments.first
    assert_equal "OBL-2009-000123", first_payment.obligation_id
    assert_equal "PMT-2009-000001", first_payment.payment_id
    assert_equal Date.new(2009, 6, 15), first_payment.paid_date
    assert_equal "CHK2009A", first_payment.check_number
    assert_equal 25000.00.to_d, first_payment.amount
    assert_equal "SEA_HOSPITAL", first_payment.vendor_name
  end

  test "parses trailer record" do
    report = Corvid::PrcReportParser.parse(SAMPLE)

    assert_equal 1, report.trailer.obligation_count
    assert_equal 1, report.trailer.patient_count
    assert_equal 2, report.trailer.payment_count
    assert_equal 42000.00.to_d, report.trailer.total_paid
    assert_equal 0.00.to_d, report.trailer.total_outstanding
  end

  test "trailer payment count matches payment record count" do
    report = Corvid::PrcReportParser.parse(SAMPLE)
    assert_equal report.trailer.payment_count, report.payments.size
  end

  test "trailer total_paid matches sum of payment amounts (integrity check)" do
    report = Corvid::PrcReportParser.parse(SAMPLE)
    summed = report.payments.sum(&:amount)
    assert_equal report.trailer.total_paid, summed
  end

  test "accepts an IO instead of a string" do
    io = StringIO.new(SAMPLE)
    report = Corvid::PrcReportParser.parse(io)
    assert_equal 1, report.obligations.size
  end

  test "skips empty lines" do
    with_blanks = SAMPLE.sub("\n", "\n\n\n")
    report = Corvid::PrcReportParser.parse(with_blanks)
    assert_equal 1, report.obligations.size
  end

  test "tolerates malformed dates by returning nil" do
    bad = "H^PRC_EXPORT^SEA^99999999^1\n"
    report = Corvid::PrcReportParser.parse(bad)
    assert_nil report.header.export_date
  end

  test "handles a multi-obligation file" do
    multi = <<~PRC
      H^PRC_EXPORT^SEA^20100506^1
      O^OBL-2010-001^DFN001^VEND01^OFFICE_VISIT_EST^20100401^A^200.00^120.00^80.00^0.00^2010
      O^OBL-2010-002^DFN002^VEND02^HIP_REPLACE_THR^20100415^A^65000.00^42000.00^23000.00^0.00^2010
      T^2^2^0^42120.00^0.00
    PRC

    report = Corvid::PrcReportParser.parse(multi)
    assert_equal 2, report.obligations.size
    assert_equal %w[OBL-2010-001 OBL-2010-002], report.obligations.map(&:obligation_id)
  end
end
