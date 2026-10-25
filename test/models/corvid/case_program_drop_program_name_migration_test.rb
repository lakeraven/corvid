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

  test "down backfills program_name from registry and up drops the column" do
    require_migration!

    enrollment = nil
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(
        patient_identifier: "pt_drop_name_mig_#{SecureRandom.hex(4)}",
        lifecycle_status: "intake",
        facility_identifier: "fac_test"
      )
      enrollment = Corvid::CaseProgram.create!(
        case: kase,
        program_code: "tb",
        enrollment_date: Date.current
      )
    end

    refute_includes Corvid::CaseProgram.column_names, "program_name",
                    "expected post-migration schema without program_name column"

    restored_up = false
    begin
      ActiveRecord::Migration.suppress_messages do
        migration.migrate(:down)
      end
      Corvid::CaseProgram.reset_column_information

      assert_includes Corvid::CaseProgram.column_names, "program_name"

      column = Corvid::CaseProgram.columns_hash.fetch("program_name")
      refute column.null, "expected program_name to be NOT NULL after migrate down"

      enrollment.reload
      assert_equal "Tuberculosis", enrollment.program_name

      ActiveRecord::Migration.suppress_messages do
        migration.migrate(:up)
      end
      Corvid::CaseProgram.reset_column_information
      restored_up = true

      refute_includes Corvid::CaseProgram.column_names, "program_name"
    ensure
      unless restored_up
        ActiveRecord::Migration.suppress_messages do
          migration.migrate(:up)
        end
        Corvid::CaseProgram.reset_column_information
      end
    end
  end
end
