# frozen_string_literal: true

require "test_helper"

class Corvid::CaseProgramDropProgramNameMigrationTest < ActiveSupport::TestCase
  TENANT = "tnt_cp_drop_name_mig"

  def migration_paths
    Dir[
      Rails.root.join("db/migrate/*_remove_program_name_from_corvid_case_programs.rb").to_s,
      Corvid::Engine.root.join("db/migrate/*_remove_program_name_from_corvid_case_programs.rb").to_s
    ]
  end

  def require_migration!
    paths = migration_paths
    flunk "expected migration file matching *_remove_program_name_from_corvid_case_programs.rb" if paths.empty?

    path = paths.first
    require path unless defined?(RemoveProgramNameFromCorvidCasePrograms)
    path
  end

  def migration
    RemoveProgramNameFromCorvidCasePrograms.new
  end

  setup do
    require_migration!
    ensure_post_migration_schema!
  end

  def ensure_post_migration_schema!
    Corvid::CaseProgram.reset_column_information
    return unless Corvid::CaseProgram.column_names.include?("program_name")

    previous = ENV["CORVID_DISCARD_PROGRAM_NAMES"]
    ENV["CORVID_DISCARD_PROGRAM_NAMES"] = "1"
    migrate_up!
    ENV["CORVID_DISCARD_PROGRAM_NAMES"] = previous
    Corvid::CaseProgram.reset_column_information
  end

  def raw_program_name(id)
    sql = ActiveRecord::Base.sanitize_sql_array(
      [ "SELECT program_name FROM corvid_case_programs WHERE id = ?", id ]
    )
    ActiveRecord::Base.connection.select_value(sql)
  end

  def migrate_down!
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    Corvid::CaseProgram.reset_column_information
  end

  def migrate_up!
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    Corvid::CaseProgram.reset_column_information
  end

  def restore_schema_up!(restored_up)
    return if restored_up

    Corvid::CaseProgram.reset_column_information
    return unless Corvid::CaseProgram.column_names.include?("program_name")

    previous = ENV["CORVID_DISCARD_PROGRAM_NAMES"]
    ENV["CORVID_DISCARD_PROGRAM_NAMES"] = "1"
    migrate_up!
    ENV["CORVID_DISCARD_PROGRAM_NAMES"] = previous
  end

  def create_enrollment!(program_code:)
    enrollment = nil
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(
        patient_identifier: "pt_drop_name_mig_#{SecureRandom.hex(4)}",
        lifecycle_status: "intake",
        facility_identifier: "fac_test"
      )
      enrollment = Corvid::CaseProgram.create!(
        case: kase,
        program_code: program_code,
        enrollment_date: Date.current
      )
    end
    enrollment
  end

  test "down backfills program_name from registry and up drops the column" do
    require_migration!

    enrollment = create_enrollment!(program_code: "tb")

    refute_includes Corvid::CaseProgram.column_names, "program_name",
                    "expected post-migration schema without program_name column"

    restored_up = false
    begin
      migrate_down!

      assert_includes Corvid::CaseProgram.column_names, "program_name"

      column = Corvid::CaseProgram.columns_hash.fetch("program_name")
      refute column.null, "expected program_name to be NOT NULL after migrate down"

      assert_equal "Tuberculosis", raw_program_name(enrollment.id)

      migrate_up!
      restored_up = true

      refute_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      restore_schema_up!(restored_up)
    end
  end

  test "down backfills raw program_name for registry display rules" do
    require_migration!

    Corvid::ProgramRegistry.register("blank_dn_mig", display_name: "", milestones: [])
    Corvid::ProgramRegistry.register("ws_dn_mig", display_name: "   ", milestones: [])
    Corvid::ProgramRegistry.register("padded_dn_mig", display_name: "  Padded Label  ", milestones: [])

    tb_row = create_enrollment!(program_code: "tb")
    blank_row = create_enrollment!(program_code: "blank_dn_mig")
    ws_row = create_enrollment!(program_code: "ws_dn_mig")
    padded_row = create_enrollment!(program_code: "padded_dn_mig")

    restored_up = false
    begin
      migrate_down!

      assert_equal "Tuberculosis", raw_program_name(tb_row.id)
      assert_equal "blank_dn_mig", raw_program_name(blank_row.id)
      assert_equal "ws_dn_mig", raw_program_name(ws_row.id)
      assert_equal "Padded Label", raw_program_name(padded_row.id)

      migrate_up!
      restored_up = true
    ensure
      Corvid::ProgramRegistry.reset!
      restore_schema_up!(restored_up)
    end
  end

  test "up raises when stored program_name differs from registry-derived name" do
    require_migration!

    enrollment = create_enrollment!(program_code: "tb")

    restored_up = false
    begin
      migrate_down!
      enrollment.reload
      enrollment.update_column(:program_name, "Legacy Custom Label")

      error = assert_raises(StandardError) do
        ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      end
      Corvid::CaseProgram.reset_column_information

      assert_match(/\d+/, error.message)
      refute_includes error.message, "Legacy Custom Label"
      assert_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      restore_schema_up!(restored_up)
    end
  end

  test "up proceeds when CORVID_DISCARD_PROGRAM_NAMES is set despite mismatched names" do
    require_migration!

    enrollment = create_enrollment!(program_code: "tb")

    restored_up = false
    previous = ENV["CORVID_DISCARD_PROGRAM_NAMES"]
    begin
      migrate_down!
      enrollment.reload
      enrollment.update_column(:program_name, "Legacy Custom Label")

      ENV["CORVID_DISCARD_PROGRAM_NAMES"] = "1"
      migrate_up!
      restored_up = true

      refute_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      ENV["CORVID_DISCARD_PROGRAM_NAMES"] = previous
      restore_schema_up!(restored_up)
    end
  end

  test "up raises when program_code is not registered" do
    require_migration!

    enrollment = create_enrollment!(program_code: "tb")

    restored_up = false
    begin
      migrate_down!
      enrollment.reload
      enrollment.update_column(:program_code, "unregistered_code")

      error = assert_raises(StandardError) do
        ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      end
      Corvid::CaseProgram.reset_column_information

      assert_match(/\d+/, error.message)
      refute_includes error.message, "unregistered_code"
      assert_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      restore_schema_up!(restored_up)
    end
  end

  test "up drops program_name when every stored name matches the registry-derived name" do
    require_migration!

    create_enrollment!(program_code: "tb")

    restored_up = false
    begin
      migrate_down!

      refute ENV.key?("CORVID_DISCARD_PROGRAM_NAMES"),
             "expected CORVID_DISCARD_PROGRAM_NAMES to be unset for clean migrate up"

      migrate_up!
      restored_up = true

      refute_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      restore_schema_up!(restored_up)
    end
  end
end
