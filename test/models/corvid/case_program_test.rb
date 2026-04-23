# frozen_string_literal: true

require "test_helper"

class Corvid::CaseProgramTest < ActiveSupport::TestCase
  TENANT = "tnt_program_test"

  setup do
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # PROGRAM TYPE VALIDATION
  # =============================================================================

  test "accepts valid program types" do
    with_tenant(TENANT) do
      Corvid::Case::PROGRAM_TYPES.each do |type|
        kase = Corvid::Case.new(patient_identifier: "pt_test", program_type: type)
        assert kase.valid?, "Expected #{type} to be a valid program_type"
      end
    end
  end

  test "rejects invalid program type" do
    with_tenant(TENANT) do
      kase = Corvid::Case.new(patient_identifier: "pt_test", program_type: "invalid_program")
      refute kase.valid?
      assert kase.errors[:program_type].any?
    end
  end

  test "allows nil program type for non-program cases" do
    with_tenant(TENANT) do
      kase = Corvid::Case.new(patient_identifier: "pt_test", program_type: nil)
      assert kase.valid?
    end
  end

  test "PROGRAM_TYPES includes all seven programs" do
    expected = %w[immunization sti tb neonatal lead hep_b communicable_disease]
    assert_equal expected.sort, Corvid::Case::PROGRAM_TYPES.sort
  end

  # =============================================================================
  # LIFECYCLE STATUS VALIDATION
  # =============================================================================

  test "defaults lifecycle_status to intake" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      assert_equal "intake", kase.lifecycle_status
    end
  end

  test "accepts valid lifecycle statuses" do
    with_tenant(TENANT) do
      Corvid::Case::LIFECYCLE_STATUSES.each do |status|
        kase = Corvid::Case.new(patient_identifier: "pt_test", lifecycle_status: status)
        assert kase.valid?, "Expected #{status} to be a valid lifecycle_status"
      end
    end
  end

  test "rejects invalid lifecycle status" do
    with_tenant(TENANT) do
      kase = Corvid::Case.new(patient_identifier: "pt_test", lifecycle_status: "bogus")
      refute kase.valid?
      assert kase.errors[:lifecycle_status].any?
    end
  end

  test "LIFECYCLE_STATUSES includes all four statuses" do
    expected = %w[intake active_followup closure closed]
    assert_equal expected.sort, Corvid::Case::LIFECYCLE_STATUSES.sort
  end

  # =============================================================================
  # LIFECYCLE TRANSITIONS
  # =============================================================================

  test "can update lifecycle_status to active_followup" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      kase.update!(lifecycle_status: "active_followup")
      assert_equal "active_followup", kase.lifecycle_status
    end
  end

  test "can update lifecycle_status to closure" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      kase.update!(lifecycle_status: "closure")
      assert_equal "closure", kase.lifecycle_status
    end
  end

  test "can update lifecycle_status to closed" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      kase.update!(lifecycle_status: "closed")
      assert_equal "closed", kase.lifecycle_status
    end
  end

  # =============================================================================
  # PROGRAM SCOPES
  # =============================================================================

  test "for_program scope filters by program_type" do
    with_tenant(TENANT) do
      imm = Corvid::Case.create!(patient_identifier: "pt_a", program_type: "immunization")
      tb = Corvid::Case.create!(patient_identifier: "pt_b", program_type: "tb")
      none = Corvid::Case.create!(patient_identifier: "pt_c")

      results = Corvid::Case.for_program("immunization")
      assert_includes results, imm
      refute_includes results, tb
      refute_includes results, none
    end
  end

  test "in_lifecycle scope filters by lifecycle_status" do
    with_tenant(TENANT) do
      intake = Corvid::Case.create!(patient_identifier: "pt_a", lifecycle_status: "intake")
      active = Corvid::Case.create!(patient_identifier: "pt_b", lifecycle_status: "active_followup")

      results = Corvid::Case.in_lifecycle("intake")
      assert_includes results, intake
      refute_includes results, active
    end
  end

  # =============================================================================
  # PROGRAM CASE PREDICATE
  # =============================================================================

  test "program_case? returns true when program_type present" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test", program_type: "immunization")
      assert kase.program_case?
    end
  end

  test "program_case? returns false when program_type nil" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      refute kase.program_case?
    end
  end

  # =============================================================================
  # CLOSED AT TRACKING
  # =============================================================================

  test "closed_at is nil by default" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      assert_nil kase.closed_at
    end
  end

  test "can store closure_reason" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_test")
      kase.update!(lifecycle_status: "closed", closure_reason: "Treatment completed")
      kase.reload
      assert_equal "Treatment completed", kase.closure_reason
    end
  end
end
