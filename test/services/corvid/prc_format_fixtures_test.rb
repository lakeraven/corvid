# frozen_string_literal: true

require "test_helper"

# Exercises the checked-in format fixtures under
# test/fixtures/overpayment_recovery/formats/.
#
# FORMAT_MATRIX.md describes what each fixture is supposed to prove, but until
# now nothing loaded them: the matrix was a promise no test kept. These cases
# bind the two fixtures this branch adds to the behavior the matrix claims for
# them, so a parser or analyzer regression fails here rather than going unnoticed.
class Corvid::PrcFormatFixturesTest < ActiveSupport::TestCase
  FORMATS_DIR = Corvid::Engine.root.join(
    "test/fixtures/overpayment_recovery/formats"
  )

  def fixture(name)
    File.read(FORMATS_DIR.join(name))
  end

  # -- unknown_record_types_v1.prc -------------------------------------------
  # Matrix: "Interleaves unknown record tags (X/Y/Z) with valid rows.
  #          Verifies parser safely ignores unknown row types."

  test "parser ignores unknown record tags and still reads the valid rows" do
    report = Corvid::PrcReportParser.parse(fixture("unknown_record_types_v1.prc"))

    assert_equal "SEA", report.header.facility
    assert_equal 1, report.obligations.size,
                 "the X/Y/Z rows must not be parsed as obligations"
    assert_equal "OBL-FMT-9101", report.obligations.first.obligation_id
    assert_equal 1, report.payments.size,
                 "the payment row after an unknown tag must still be read"
    assert_equal "PMT-FMT-9101", report.payments.first.payment_id
    assert_equal 1, report.trailer.obligation_count
  end

  # -- unmapped_facility_v1.prc ----------------------------------------------
  # Matrix: "Header facility code not in facility dictionary (XYZ).
  #          Verifies analyzer returns :unmapped_facility paths."

  test "analyzer flags every row as :unmapped_facility for an unknown facility code" do
    report = Corvid::PrcReportParser.parse(fixture("unmapped_facility_v1.prc"))
    assert_equal "XYZ", report.header.facility
    assert_nil Corvid::PrcFacilityDictionary.lookup("XYZ"),
               "fixture premise: XYZ must not be in the facility dictionary"

    summary = Corvid::PrcOverpaymentAnalyzer.analyze(report)

    assert_equal 2, summary.results.size
    summary.results.each do |result|
      assert_equal :unmapped_facility, result.recovery_confidence
      assert_nil result.medicare_equivalent,
                 "no Medicare rate can be computed without a mapped facility"
      assert_nil result.rate_source,
                 "rate_source must stay nil when no rate was computed"
      assert_nil result.rate_source_release,
                 "an unpriced row must contribute no release to the manifest"
    end
  end
end
