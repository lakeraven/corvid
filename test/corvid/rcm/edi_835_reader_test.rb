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
                 .sub("SE*12*0001~", "CLP*CLM-1099*1*150.00*150.00*0*12*PAYER-CTL-1099*11~SE*13*0001~")
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

  # -- the X12 envelope ------------------------------------------------------
  #
  # The fixtures are only evidence about real 835 syntax if their envelopes are
  # real: ISA is fixed-width (106 characters, 15-character sender/receiver
  # ids), GS02/GS03 are at most 15 characters, and SE01 counts the segments
  # from ST through SE inclusive.

  def fixture_lines(scenario)
    File.read(File.join(FIXTURES, "#{scenario}.835")).split("~").map(&:strip).reject(&:empty?)
  end

  def test_every_fixture_has_a_fixed_width_isa_envelope
    Corvid::Rcm::FixtureClearinghouseClient::SCENARIOS.each do |scenario|
      isa = fixture_lines(scenario).first
      elements = isa.split("*", -1)

      assert_equal 106, isa.length + 1, "#{scenario}: ISA must be 106 characters including its terminator"
      assert_equal 15, elements[6].length, "#{scenario}: ISA06 sender id must be 15 characters"
      assert_equal 15, elements[8].length, "#{scenario}: ISA08 receiver id must be 15 characters"
    end
  end

  def test_every_fixture_keeps_gs_application_codes_within_15_characters
    Corvid::Rcm::FixtureClearinghouseClient::SCENARIOS.each do |scenario|
      gs = fixture_lines(scenario).find { |segment| segment.start_with?("GS*") }.split("*", -1)

      assert_operator gs[2].length, :<=, 15, "#{scenario}: GS02 is longer than 15 characters"
      assert_operator gs[3].length, :<=, 15, "#{scenario}: GS03 is longer than 15 characters"
    end
  end

  def test_every_fixture_declares_the_segment_count_it_actually_has
    Corvid::Rcm::FixtureClearinghouseClient::SCENARIOS.each do |scenario|
      lines = fixture_lines(scenario)
      st = lines.index { |segment| segment.start_with?("ST*") }
      se = lines.index { |segment| segment.start_with?("SE*") }

      assert_equal se - st + 1, lines[se].split("*")[1].to_i, "#{scenario}: SE01 does not match its ST..SE count"
    end
  end

  def test_a_transaction_whose_se_count_disagrees_with_its_segments_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835")).sub("SE*12*0001~", "SE*20*0001~")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/SE01/, error.message)
  end

  # A file cut off after its last claim loop still balances, so the SE trailer
  # is the only thing that can tell it was truncated.
  def test_a_transaction_with_no_se_trailer_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835")).sub(/SE\*12\*0001~.*\z/m, "")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/SE/, error.message)
  end

  # -- a CAS segment has to carry an adjustment --------------------------------

  def test_a_cas_segment_with_no_adjustment_at_all_raises
    source = File.read(File.join(FIXTURES, "denial_bundled_co97.835")).sub("CAS*CO*97*45.00~", "CAS*CO~")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/CAS/, error.message)
  end

  # -- panel round 1: CLP01 and CLP02 are required ------------------------------

  def test_a_claim_loop_with_no_status_code_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835")).sub("CLP*CLM-1001*1*", "CLP*CLM-1001**")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/CLP02/, error.message)
  end

  def test_a_claim_loop_with_no_claim_identifier_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835")).sub("CLP*CLM-1001*", "CLP**")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/CLP01/, error.message)
  end

  # -- panel round 2 ------------------------------------------------------------

  def test_a_non_finite_amount_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835")).sub("SVC*HC>90837*200.00*200.00", "SVC*HC>90837*200.00*Infinity")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/Infinity/, error.message)
  end

  # Claim loops after SE are outside the transaction its count covers.
  def test_a_claim_loop_outside_the_st_se_transaction_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835"))
                 .sub("SE*12*0001~", "SE*12*0001~CLP*CLM-1098*1*0.00*0.00*0*12*PAYER-CTL-1098*11~")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/outside the ST\/SE transaction/, error.message)
  end

  # -- panel round 3 ------------------------------------------------------------

  def test_a_claim_loop_before_the_st_header_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835"))
                 .sub("ST*835*0001~", "CLP*ROGUE-1*1*0.00*0.00*0*12*PAYER-CTL-0*11~ST*835*0001~")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/outside the ST\/SE transaction/, error.message)
  end

  def test_a_service_line_with_no_procedure_code_raises
    source = File.read(File.join(FIXTURES, "clean_full_pay.835")).sub("SVC*HC>90837*", "SVC*HC*")
    error = assert_raises(Corvid::Rcm::Edi835Reader::ParseError) do
      Corvid::Rcm::Edi835Reader.new(source).parse
    end

    assert_match(/SVC01/, error.message)
  end
end
