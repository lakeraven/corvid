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
end
