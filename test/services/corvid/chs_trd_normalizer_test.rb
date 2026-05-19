# frozen_string_literal: true

require "test_helper"
require "bigdecimal"

class Corvid::ChsTrdNormalizerTest < ActiveSupport::TestCase
  CANONICAL_CSV = <<~CSV
    document_number,patient_dfn,vendor_name,procedure_code,service_date,paid_amount
    1234567,12345,ACME REGIONAL HOSPITAL,99213,2024-06-15,180.00
    1234568,12346,BETA CLINIC,99214,2024-06-16,250.50
  CSV

  test "clean canonical CSV returns all rows and no rejects" do
    result = Corvid::ChsTrdNormalizer.normalize(CANONICAL_CSV)
    assert_equal 2, result[:rows].size
    assert_empty result[:rejects]

    first = result[:rows][0]
    assert_equal "1234567", first[:document_number]
    assert_equal "12345", first[:patient_dfn]
    assert_equal "ACME REGIONAL HOSPITAL", first[:vendor_name]
    assert_equal "99213", first[:procedure_code]
    assert_equal "2024-06-15", first[:service_date]
    assert_equal BigDecimal("180.00"), first[:paid_amount]
  end

  test "missing required header raises ArgumentError" do
    csv = <<~CSV
      document_number,vendor_name,procedure_code,service_date
      1234567,ACME,99213,2024-06-15
    CSV
    assert_raises(ArgumentError) do
      Corvid::ChsTrdNormalizer.normalize(csv)
    end
  end

  test "row missing required field is rejected with reason and line number" do
    csv = <<~CSV
      document_number,vendor_name,procedure_code,service_date,paid_amount
      ,ACME REGIONAL,99213,2024-06-15,100.00
      1234568,,99214,2024-06-16,150.00
      1234569,GOOD ROW,99215,2024-06-17,200.00
    CSV
    result = Corvid::ChsTrdNormalizer.normalize(csv)
    assert_equal 1, result[:rows].size
    assert_equal "1234569", result[:rows][0][:document_number]
    assert_equal 2, result[:rejects].size

    line1_reject = result[:rejects].find { |r| r[:line] == 1 }
    assert_match(/document_number/, line1_reject[:reason])

    line2_reject = result[:rejects].find { |r| r[:line] == 2 }
    assert_match(/vendor_name/, line2_reject[:reason])
  end

  test "malformed service_date is rejected" do
    csv = <<~CSV
      document_number,vendor_name,procedure_code,service_date,paid_amount
      1234567,ACME,99213,NOT-A-DATE,100.00
      1234568,GOOD,99214,2024-06-16,150.00
    CSV
    result = Corvid::ChsTrdNormalizer.normalize(csv)
    assert_equal 1, result[:rows].size
    assert_equal "1234568", result[:rows][0][:document_number]
    assert_equal 1, result[:rejects].size
    assert_equal 1, result[:rejects][0][:line]
    assert_match(/service_date/, result[:rejects][0][:reason])
  end

  test "malformed paid_amount is rejected" do
    csv = <<~CSV
      document_number,vendor_name,procedure_code,service_date,paid_amount
      1234567,ACME,99213,2024-06-15,not-a-number
      1234568,GOOD,99214,2024-06-16,150.00
    CSV
    result = Corvid::ChsTrdNormalizer.normalize(csv)
    assert_equal 1, result[:rows].size
    assert_equal "1234568", result[:rows][0][:document_number]
    assert_equal 1, result[:rejects].size
    assert_equal 1, result[:rejects][0][:line]
    assert_match(/paid_amount/, result[:rejects][0][:reason])
  end

  test "optional columns absent: row included, optional fields nil" do
    csv = <<~CSV
      document_number,vendor_name,procedure_code,service_date,paid_amount
      1234567,ACME REGIONAL,99213,2024-06-15,180.00
    CSV
    result = Corvid::ChsTrdNormalizer.normalize(csv)
    assert_equal 1, result[:rows].size
    assert_empty result[:rejects]
    row = result[:rows][0]
    assert_nil row[:patient_dfn]
    assert_nil row[:place_of_service]
    assert_nil row[:modifiers]
    assert_nil row[:drg]
    assert_nil row[:apc]
    assert_nil row[:facility_zip]
  end

  test "optional columns present pass through to output row" do
    csv = <<~CSV
      document_number,patient_dfn,vendor_name,procedure_code,service_date,paid_amount,place_of_service,modifiers,drg,apc,facility_zip
      1234567,12345,ACME REGIONAL,99213,2024-06-15,180.00,11,25,470,5071,98948
    CSV
    result = Corvid::ChsTrdNormalizer.normalize(csv)
    assert_equal 1, result[:rows].size
    assert_empty result[:rejects]
    row = result[:rows][0]
    assert_equal "11", row[:place_of_service]
    assert_equal "25", row[:modifiers]
    assert_equal "470", row[:drg]
    assert_equal "5071", row[:apc]
    assert_equal "98948", row[:facility_zip]
  end

  test "accepts IO input as well as String" do
    io = StringIO.new(CANONICAL_CSV)
    result = Corvid::ChsTrdNormalizer.normalize(io)
    assert_equal 2, result[:rows].size
    assert_empty result[:rejects]
  end

  test "strips whitespace from required string fields" do
    csv = <<~CSV
      document_number,vendor_name,procedure_code,service_date,paid_amount
        1234567  ,  ACME REGIONAL  ,  99213  ,2024-06-15,180.00
    CSV
    result = Corvid::ChsTrdNormalizer.normalize(csv)
    assert_equal 1, result[:rows].size
    row = result[:rows][0]
    assert_equal "1234567", row[:document_number]
    assert_equal "ACME REGIONAL", row[:vendor_name]
    assert_equal "99213", row[:procedure_code]
  end
end
