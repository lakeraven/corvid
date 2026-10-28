# frozen_string_literal: true

require "test_helper"

class Corvid::RenameChecklistActorIdentifiersMigrationTest < ActiveSupport::TestCase
  TENANT = "tnt_rename_checklist_actor_identifiers"

  setup do
    @migration = load_rename_checklist_actor_identifiers_migration
    @migrated_down = false
  end

  teardown do
    if @migration
      if @migrated_down && checklist_by_columns_present?
        migrate_silent(:up)
      end
      Corvid::EligibilityChecklist.reset_column_information
    end
  end

  test "down then up round-trips checklist actor identifier columns" do
    assert_migration_file!
    checklist = create_checklist_row!
    set_checklist_by_values!(checklist, application_completed_by: "pr_round_a", management_approved_by: "pr_round_b")

    migrate_silent(:down)
    Corvid::EligibilityChecklist.reset_column_information
    assert checklist_by_columns_present?

    checklist.reload
    assert_equal "pr_round_a", checklist.read_attribute(:application_completed_by)
    assert_equal "pr_round_b", checklist.read_attribute(:management_approved_by)

    migrate_silent(:up)
    Corvid::EligibilityChecklist.reset_column_information
    assert checklist_by_identifier_columns_present?

    checklist.reload
    assert_equal "pr_round_a", checklist.read_attribute(:application_completed_by_identifier)
    assert_equal "pr_round_b", checklist.read_attribute(:management_approved_by_identifier)
  end

  private

  def load_rename_checklist_actor_identifiers_migration
    paths = Dir[
      Corvid::Engine.root.join("db/migrate/*_rename_checklist_actor_identifiers.rb").to_s
    ]
    return nil if paths.empty?

    path = paths.first
    require path unless defined?(RenameChecklistActorIdentifiers)
    RenameChecklistActorIdentifiers.new
  end

  def assert_migration_file!
    flunk "expected migration file matching *_rename_checklist_actor_identifiers.rb" unless @migration
  end

  def migrate_silent(direction)
    ActiveRecord::Migration.suppress_messages do
      @migration.migrate(direction)
    end
    case direction
    when :down then @migrated_down = true
    when :up then @migrated_down = false
    end
  end

  def create_checklist_row!
    with_tenant(TENANT) do
      case_record = Corvid::Case.create!(patient_identifier: "pt_mig_chk")
      referral = Corvid::PrcReferral.create!(
        case: case_record,
        referral_identifier: "rf_mig_chk"
      )
      Corvid::EligibilityChecklist.create!(prc_referral: referral)
    end
  end

  def set_checklist_by_values!(checklist, application_completed_by:, management_approved_by:)
    if checklist_by_columns_present?
      checklist.update_columns(
        application_completed_by: application_completed_by,
        management_approved_by: management_approved_by
      )
    else
      checklist.update_columns(
        application_completed_by_identifier: application_completed_by,
        management_approved_by_identifier: management_approved_by
      )
    end
  end

  def checklist_by_columns_present?
    Corvid::EligibilityChecklist.column_names.include?("application_completed_by")
  end

  def checklist_by_identifier_columns_present?
    Corvid::EligibilityChecklist.column_names.include?("application_completed_by_identifier")
  end
end
