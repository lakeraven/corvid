# frozen_string_literal: true

require "test_helper"

class Corvid::CaseProgramDropProgramNameMigrationTest < ActiveSupport::TestCase
  TENANT = "tnt_cp_drop_name_mig"

  def unmapped_program_names_error
    RemoveProgramNameFromCorvidCasePrograms::UnmappedProgramNames
  end

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
    restart_case_programs_id_sequence!
  end

  def restart_case_programs_id_sequence!
    conn = ActiveRecord::Base.connection
    seq = conn.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT pg_get_serial_sequence(?, ?)", "corvid_case_programs", "id" ]
      )
    )
    flunk "expected serial sequence for corvid_case_programs.id" if seq.blank?

    conn.execute("ALTER SEQUENCE #{seq} RESTART WITH 900001")
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

  def store_program_name!(enrollment, program_name)
    enrollment.reload
    enrollment.update_columns(program_name: program_name)
  end

  def refute_message_includes_row_ids!(message, *rows)
    rows.each do |row|
      id = row.id.to_s
      refute_includes message, id, "expected message not to include row id #{id}"
      refute_match(/\b#{id}\b/, message, "expected message not to include row id #{id} as a token")
    end
  end

  def assert_raises_unmapped!(*rows, expected_mismatched:, expected_unregistered:)
    error = assert_raises(unmapped_program_names_error) do
      ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    end
    Corvid::CaseProgram.reset_column_information
    message = error.message
    refute_message_includes_row_ids!(message, *rows)
    assert_includes message, "#{expected_mismatched} stored label(s)"
    assert_includes message, "#{expected_unregistered} program code(s)"
    rows.each do |row|
      row.reload
      label = raw_program_name(row.id)
      refute_includes message, label.to_s if label.present?
      refute_includes message, row.program_code.to_s
    end
    error
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

  test "up accepts label written by ProgramTemplateService display_name.presence rule" do
    require_migration!

    code = "access_nl_hist_mig"
    label = "ACCESS Example Program\n"
    Corvid::ProgramRegistry.register(code, display_name: label, milestones: [])

    enrollment = create_enrollment!(program_code: code)

    restored_up = false
    begin
      migrate_down!
      store_program_name!(enrollment, label)

      refute ENV.key?("CORVID_DISCARD_PROGRAM_NAMES"),
             "expected CORVID_DISCARD_PROGRAM_NAMES to be unset"

      migrate_up!
      restored_up = true

      refute_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      Corvid::ProgramRegistry.reset!
      restore_schema_up!(restored_up)
    end
  end

  test "up accepts label written by migration 20260506 display_name || program_code rule for padded display_name" do
    require_migration!

    code = "padded_hist_mig"
    display_name = "  Padded  "
    Corvid::ProgramRegistry.register(code, display_name: display_name, milestones: [])

    enrollment = create_enrollment!(program_code: code)

    restored_up = false
    begin
      migrate_down!
      store_program_name!(enrollment, display_name)

      migrate_up!
      restored_up = true

      refute_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      Corvid::ProgramRegistry.reset!
      restore_schema_up!(restored_up)
    end
  end

  test "up accepts label written by migration 20260506 rule for whitespace-only display_name" do
    require_migration!

    code = "ws_only_hist_mig"
    display_name = "   "
    Corvid::ProgramRegistry.register(code, display_name: display_name, milestones: [])

    enrollment = create_enrollment!(program_code: code)

    restored_up = false
    begin
      migrate_down!
      store_program_name!(enrollment, display_name)

      migrate_up!
      restored_up = true

      refute_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      Corvid::ProgramRegistry.reset!
      restore_schema_up!(restored_up)
    end
  end

  test "up raises when stored program_name differs from every historical and registry-derived name" do
    require_migration!

    enrollment = create_enrollment!(program_code: "tb")

    restored_up = false
    begin
      migrate_down!
      store_program_name!(enrollment, "Legacy Custom Label")

      assert_raises_unmapped!(enrollment, expected_mismatched: 1, expected_unregistered: 0)

      assert_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      restore_schema_up!(restored_up)
    end
  end

  test "up proceeds when CORVID_DISCARD_PROGRAM_NAMES is 1 despite mismatched names" do
    require_migration!

    enrollment = create_enrollment!(program_code: "tb")

    restored_up = false
    previous = ENV["CORVID_DISCARD_PROGRAM_NAMES"]
    begin
      migrate_down!
      store_program_name!(enrollment, "Legacy Custom Label")

      ENV["CORVID_DISCARD_PROGRAM_NAMES"] = "1"
      migrate_up!
      restored_up = true

      refute_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      ENV["CORVID_DISCARD_PROGRAM_NAMES"] = previous
      restore_schema_up!(restored_up)
    end
  end

  test "up still raises on custom label when CORVID_DISCARD_PROGRAM_NAMES is 0" do
    require_migration!

    enrollment = create_enrollment!(program_code: "tb")

    restored_up = false
    previous = ENV["CORVID_DISCARD_PROGRAM_NAMES"]
    begin
      migrate_down!
      store_program_name!(enrollment, "Legacy Custom Label")

      ENV["CORVID_DISCARD_PROGRAM_NAMES"] = "0"
      assert_raises_unmapped!(enrollment, expected_mismatched: 1, expected_unregistered: 0)
      assert_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      ENV["CORVID_DISCARD_PROGRAM_NAMES"] = previous
      restore_schema_up!(restored_up)
    end
  end

  test "up still raises on custom label when CORVID_DISCARD_PROGRAM_NAMES is true" do
    require_migration!

    enrollment = create_enrollment!(program_code: "tb")

    restored_up = false
    previous = ENV["CORVID_DISCARD_PROGRAM_NAMES"]
    begin
      migrate_down!
      store_program_name!(enrollment, "Legacy Custom Label")

      ENV["CORVID_DISCARD_PROGRAM_NAMES"] = "true"
      assert_raises_unmapped!(enrollment, expected_mismatched: 1, expected_unregistered: 0)
      assert_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      ENV["CORVID_DISCARD_PROGRAM_NAMES"] = previous
      restore_schema_up!(restored_up)
    end
  end

  test "up raises when program_code is not registered even if stored label equals the code" do
    require_migration!

    unregistered_code = "unreg_label_eq_code_mig"
    refute Corvid::ProgramRegistry.exists?(unregistered_code)

    enrollment = create_enrollment!(program_code: "tb")

    restored_up = false
    begin
      migrate_down!
      enrollment.reload
      enrollment.update_columns(program_code: unregistered_code, program_name: unregistered_code)

      assert_raises_unmapped!(enrollment, expected_mismatched: 0, expected_unregistered: 1)

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
