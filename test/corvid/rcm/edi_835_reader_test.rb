# frozen_string_literal: true

require "minitest/autorun"
require "corvid/rcm"

class Corvid::Rcm::Edi835ReaderTest < Minitest::Test
  FIXTURES = Corvid::Rcm::FixtureClearinghouseClient::FIXTURE_DIR

  def read(scenario)
    Corvid::Rcm::Edi835Reader.read(File.join(FIXTURES, "#{scenario}.835"))
  end

  # -- envelope --------------------------------------------------------------

  def test_reads_payment_envelope_from_bpr_and_trn
    remittance = read("clean_full_pay")

    assert_equal "REMIT-2026-0901-0001", remittance.remittance_identifier
    assert_equal "EXAMPLE HEALTH PLAN", remittance.payer_name
    assert_equal "1999999992", remittance.payee_identifier
    assert_equal "ACH", remittance.payment_method
    assert_equal BigDecimal("200.00"), remittance.payment_amount
    assert_equal Date.new(2026, 9, 1), remittance.payment_date
    assert_equal "USD", remittance.currency
  end

  def test_every_fixture_balances_claim_payments_against_the_bpr_total
    Corvid::Rcm::FixtureClearinghouseClient::SCENARIOS.each do |scenario|
      assert read(scenario).balanced?, "#{scenario} does not balance to its BPR total"
    end
  end

  def test_reads_the_claim_loop
    claim = read("clean_full_pay").claim("CLM-1001")

    assert_equal "1", claim.status_code
    assert_equal "PAYER-CTL-1001", claim.payer_control_number
    assert_equal BigDecimal("200.00"), claim.billed_amount
    assert_equal BigDecimal("200.00"), claim.paid_amount
    assert_equal Date.new(2026, 8, 15), claim.serviced_date
    assert_equal "MBR0001", claim.patient_identifier
  end

  def test_reads_service_lines_with_composite_procedure_and_modifiers
    claim = read("denial_authorization_required_co197").claim("CLM-1008")
    service = claim.services.first

    assert_equal "90837", service.procedure_code
    assert_equal [ "95" ], service.modifiers
    assert_equal 1, service.units
    assert_equal Date.new(2026, 8, 26), service.serviced_date
  end

  def test_reads_multiple_service_lines_and_attaches_cas_to_the_right_one
    claim = read("denial_bundled_co97").claim("CLM-1007")

    assert_equal 2, claim.services.length
    paid, bundled = claim.services
    assert_empty paid.adjustment_codes
    assert_equal [ "CO-97" ], bundled.adjustment_codes
    assert_equal BigDecimal("45.00"), bundled.contractual_amount
  end

  def test_reads_remark_codes_from_lq_segments
    claim = read("denial_missing_information_co16").claim("CLM-1003")

    assert_equal [ "N286" ], claim.all_remark_codes
  end

  def test_parses_multi_triplet_cas_segments
    claim = read("partial_pay_patient_responsibility").claim("CLM-1002")

    assert_equal [ "CO-45", "PR-1", "PR-2", "PR-3" ], claim.adjustment_codes
    assert_equal BigDecimal("50.00"), claim.contractual_amount
  end

  # -- error handling --------------------------------------------------------

  def test_raises_rather_than_returning_a_half_parsed_file
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new("ST*835*0001~SE*1*0001~").parse
    end
    assert_match(/no CLP claim loops/, error.message)
  end

  def test_raises_on_a_service_line_outside_a_claim_loop
    assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new("TRN*1*X*1~SVC*HC>90837*200.00*200.00**1~").parse
    end
  end

  def test_raises_on_an_unparseable_amount
    source = "TRN*1*X*1~CLP*CLM-1*1*not-a-number*0*0*12*CTL*11~"
    assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end
  end

  # -- the file has to balance -----------------------------------------------
  #
  # Regression: the balance assertion used to live only in the tests, so a
  # production file truncated after the first CLP loop parsed "successfully"
  # and the missing claims — and their money — simply were not there.

  # The payer says it paid $350 and only the first $200 claim loop arrived —
  # exactly the shape of a file cut short in transmission.
  def test_a_file_truncated_after_the_first_claim_loop_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835")).sub("BPR*I*200.00*", "BPR*I*350.00*")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/does not balance/, error.message)
    assert_match(/350\.0/, error.message)
    assert_match(/200\.0/, error.message)
  end

  def test_a_file_that_balances_across_several_claim_loops_parses
    source = File.read(File.join(FIXTURES, "clean_full_pay.835"))
                 .sub("BPR*I*200.00*", "BPR*I*350.00*")
                 .sub("SE*13*0001~", "CLP*CLM-1099*1*150.00*150.00*0*12*PAYER-CTL-1099*11~SE*15*0001~")
    remittance = Corvid::Rcm::Edi835Reader.new(source).parse

    assert_equal 2, remittance.claims.length
    assert remittance.balanced?
  end

  # -- a missing amount is an error, not a silent zero ------------------------

  def test_a_claim_loop_with_no_paid_amount_raises_rather_than_posting_zero
    source = "TRN*1*X*1~BPR*I*200.00*C*ACH~CLP*CLM-1*1*200.00**0*12*CTL*11~"
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/missing CLP04 paid amount/, error.message)
  end

  def test_an_adjustment_with_no_amount_raises_rather_than_adjusting_zero
    source = "TRN*1*X*1~BPR*I*0.00*C*NON~CLP*CLM-1*4*200.00*0.00*0*12*CTL*11~CAS*CO*45~"
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/missing CAS amount for CO-45/, error.message)
  end

  def test_a_service_line_with_no_paid_amount_raises
    source = "TRN*1*X*1~BPR*I*200.00*C*ACH~CLP*CLM-1*1*200.00*200.00*0*12*CTL*11~SVC*HC>90837*200.00**1~"
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/missing SVC03 paid amount/, error.message)
  end

  def test_a_file_with_no_payment_amount_at_all_raises
    source = "TRN*1*X*1~CLP*CLM-1*1*200.00*200.00*0*12*CTL*11~"
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/BPR02/, error.message)
  end
end
