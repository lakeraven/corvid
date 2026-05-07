# frozen_string_literal: true

require "test_helper"

class Corvid::PrcProcedureDictionaryTest < ActiveSupport::TestCase
  def teardown
    Corvid::PrcProcedureDictionary.reset!
  end

  test "ships built-in mapping for major joint replacement" do
    entry = Corvid::PrcProcedureDictionary.lookup("HIP_REPLACE_THR")
    assert_equal "27130", entry.hcpcs
    assert_equal "470", entry.drg
    assert_match(/hip arthroplasty/i, entry.description)
  end

  test "ships built-in mapping for office visit (professional only, no DRG)" do
    entry = Corvid::PrcProcedureDictionary.lookup("OFFICE_VISIT_EST")
    assert_equal "99213", entry.hcpcs
    assert_nil entry.drg
    assert_nil entry.apc
  end

  test "lookup returns nil for unknown code" do
    assert_nil Corvid::PrcProcedureDictionary.lookup("DOES_NOT_EXIST")
  end

  test "host can register custom mappings via initializer" do
    Corvid::PrcProcedureDictionary.register(
      "CUSTOM_PROC",
      hcpcs: "12345",
      drg: "999",
      description: "Custom procedure"
    )

    entry = Corvid::PrcProcedureDictionary.lookup("CUSTOM_PROC")
    assert_equal "12345", entry.hcpcs
    assert_equal "999", entry.drg
  end

  test "reset! restores defaults and drops host registrations" do
    Corvid::PrcProcedureDictionary.register("TEMP", hcpcs: "00001")
    assert Corvid::PrcProcedureDictionary.lookup("TEMP")

    Corvid::PrcProcedureDictionary.reset!

    assert_nil Corvid::PrcProcedureDictionary.lookup("TEMP"),
               "reset! should drop host-registered codes"
    assert Corvid::PrcProcedureDictionary.lookup("HIP_REPLACE_THR"),
           "reset! should restore built-in defaults"
  end
end
