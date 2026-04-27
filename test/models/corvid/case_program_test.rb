# frozen_string_literal: true

require "test_helper"

class Corvid::CaseProgramTest < ActiveSupport::TestCase
  TENANT = "tnt_cp_test"

  setup do
    Corvid::CaseProgram.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # -- Creation ---------------------------------------------------------------

  test "creates with case and program_name" do
    with_tenant(TENANT) do
      cp = create_case_program
      assert cp.persisted?
      assert_equal "IHS CHS", cp.program_name
    end
  end

  test "belongs to case" do
    with_tenant(TENANT) do
      cp = create_case_program
      assert_instance_of Corvid::Case, cp.case
    end
  end

  # -- Validations -----------------------------------------------------------

  test "requires program_name" do
    with_tenant(TENANT) do
      cp = Corvid::CaseProgram.new(case: create_case, program_name: nil, program_code: "CHS")
      refute cp.valid?
      assert cp.errors[:program_name].any?
    end
  end

  test "requires program_code" do
    with_tenant(TENANT) do
      cp = Corvid::CaseProgram.new(case: create_case, program_name: "IHS CHS", program_code: nil)
      refute cp.valid?
      assert cp.errors[:program_code].any?
    end
  end

  test "enrollment_status must be a valid value" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) do
        Corvid::CaseProgram.new(
          case: create_case, program_name: "IHS CHS",
          program_code: "CHS", enrollment_status: "bogus"
        )
      end
    end
  end

  test "requires enrollment_date" do
    with_tenant(TENANT) do
      cp = Corvid::CaseProgram.new(
        case: create_case, program_name: "Medicare", program_code: "MCR",
        enrollment_date: nil
      )
      refute cp.valid?
      assert cp.errors[:enrollment_date].any?
    end
  end

  test "program_code must be unique per case" do
    with_tenant(TENANT) do
      kase = create_case
      Corvid::CaseProgram.create!(
        case: kase, program_name: "IHS CHS", program_code: "CHS",
        enrollment_date: Date.current
      )
      dup = Corvid::CaseProgram.new(
        case: kase, program_name: "IHS CHS", program_code: "CHS",
        enrollment_date: Date.current
      )
      refute dup.valid?
      assert dup.errors[:program_code].any?
    end
  end

  test "same program_code can exist for different cases" do
    with_tenant(TENANT) do
      c1 = create_case
      c2 = create_case
      Corvid::CaseProgram.create!(case: c1, program_name: "CHS", program_code: "CHS", enrollment_date: Date.current)
      cp2 = Corvid::CaseProgram.new(case: c2, program_name: "CHS", program_code: "CHS", enrollment_date: Date.current)
      assert cp2.valid?
    end
  end

  test "disenrollment_date must be on or after enrollment_date" do
    with_tenant(TENANT) do
      cp = Corvid::CaseProgram.new(
        case: create_case, program_name: "Medicare", program_code: "MCR",
        enrollment_date: Date.current, disenrollment_date: 1.day.ago.to_date
      )
      refute cp.valid?
      assert cp.errors[:disenrollment_date].any?
    end
  end

  test "disenrollment_date on enrollment_date is valid" do
    with_tenant(TENANT) do
      cp = Corvid::CaseProgram.new(
        case: create_case, program_name: "Medicare", program_code: "MCR",
        enrollment_date: Date.current, disenrollment_date: Date.current
      )
      assert cp.valid?
    end
  end

  # -- Enrollment status enum ------------------------------------------------

  test "defaults enrollment_status to active" do
    with_tenant(TENANT) do
      cp = create_case_program
      assert_equal "active", cp.enrollment_status
    end
  end

  test "enrollment_status enum includes expected values" do
    expected = %w[active inactive pending terminated]
    assert_equal expected.sort, Corvid::CaseProgram.enrollment_statuses.keys.sort
  end

  # -- Scopes ----------------------------------------------------------------

  test "active_enrollment scope" do
    with_tenant(TENANT) do
      active = create_case_program(enrollment_status: "active")
      inactive = create_case_program(program_code: "MCR", enrollment_status: "inactive")

      assert_includes Corvid::CaseProgram.active_enrollment, active
      refute_includes Corvid::CaseProgram.active_enrollment, inactive
    end
  end

  test "for_program scope filters by program_code" do
    with_tenant(TENANT) do
      chs = create_case_program(program_code: "CHS")
      mcr = create_case_program(program_code: "MCR")

      results = Corvid::CaseProgram.for_program("CHS")
      assert_includes results, chs
      refute_includes results, mcr
    end
  end

  test "currently_enrolled scope returns active without disenrollment" do
    with_tenant(TENANT) do
      current = create_case_program(enrollment_status: "active", disenrollment_date: nil)
      disenrolled = create_case_program(
        program_code: "MCR", enrollment_status: "active",
        enrollment_date: 1.month.ago.to_date,
        disenrollment_date: 1.day.ago.to_date
      )

      results = Corvid::CaseProgram.currently_enrolled
      assert_includes results, current
      refute_includes results, disenrolled
    end
  end

  # -- Predicates ------------------------------------------------------------

  test "enrolled? returns true for active enrollment" do
    with_tenant(TENANT) do
      cp = create_case_program(enrollment_status: "active")
      assert cp.enrolled?
    end
  end

  test "enrolled? returns false for terminated enrollment" do
    with_tenant(TENANT) do
      cp = create_case_program(enrollment_status: "terminated")
      refute cp.enrolled?
    end
  end

  test "disenrolled? returns true when disenrollment_date is set" do
    with_tenant(TENANT) do
      cp = create_case_program(disenrollment_date: Date.current)
      assert cp.disenrolled?
    end
  end

  test "disenrolled? returns false when disenrollment_date is nil" do
    with_tenant(TENANT) do
      cp = create_case_program
      refute cp.disenrolled?
    end
  end

  # -- Disenroll method ------------------------------------------------------

  test "disenroll! sets disenrollment_date and marks terminated" do
    with_tenant(TENANT) do
      cp = create_case_program
      cp.disenroll!
      cp.reload

      assert_equal Date.current, cp.disenrollment_date
      assert_equal "terminated", cp.enrollment_status
    end
  end

  test "disenroll! accepts custom date" do
    with_tenant(TENANT) do
      custom_date = 1.week.ago.to_date
      cp = create_case_program(enrollment_date: 1.month.ago.to_date)
      cp.disenroll!(as_of: custom_date)
      cp.reload

      assert_equal custom_date, cp.disenrollment_date
    end
  end

  # -- TenantScoped ----------------------------------------------------------

  test "case programs are scoped to current tenant" do
    other_tenant = "tnt_cp_other"
    in_tenant = nil
    outside = nil

    with_tenant(TENANT) do
      in_tenant = create_case_program
    end

    with_tenant(other_tenant) do
      outside = create_case_program
    end

    with_tenant(TENANT) do
      visible = Corvid::CaseProgram.all
      assert_includes visible, in_tenant
      refute_includes visible, outside
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: "pt_cp_test_#{SecureRandom.hex(4)}",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_case_program(program_name: "IHS CHS", program_code: "CHS", enrollment_status: "active", **attrs)
    Corvid::CaseProgram.create!(
      case: attrs.delete(:case) || create_case,
      program_name: program_name,
      program_code: program_code,
      enrollment_status: enrollment_status,
      enrollment_date: attrs.delete(:enrollment_date) || Date.current,
      **attrs
    )
  end
end
