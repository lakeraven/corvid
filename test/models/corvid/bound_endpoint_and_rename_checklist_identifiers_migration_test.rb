# frozen_string_literal: true

require "test_helper"

class Corvid::BoundEndpointAndRenameChecklistIdentifiersMigrationTest < ActiveSupport::TestCase
  TENANT = "tnt_bound_endpoint_migration"
  ENDPOINT_CHECK = "corvid_api_call_logs_endpoint_check"
  BAD_ENDPOINT = "/Patient/pt_123"

  setup do
    @migration = load_bound_endpoint_migration
    @migrated_down = false
  end

  teardown do
    if @migration
      delete_api_call_logs!
      if @migrated_down && checklist_by_columns_present?
        migrate_silent(:up)
      end
      Corvid::ApiCallLog.reset_column_information
      Corvid::EligibilityChecklist.reset_column_information
    end
  end

  test "down then up round-trips checklist identifier columns and endpoint check" do
    assert_migration_file!
    checklist = create_checklist_row!
    set_checklist_by_values!(checklist, application_completed_by: "pr_round_a", management_approved_by: "pr_round_b")

    migrate_silent(:down)
    Corvid::EligibilityChecklist.reset_column_information
    assert checklist_by_columns_present?
    refute endpoint_check_constraint_exists?

    checklist.reload
    assert_equal "pr_round_a", checklist.read_attribute(:application_completed_by)
    assert_equal "pr_round_b", checklist.read_attribute(:management_approved_by)

    migrate_silent(:up)
    Corvid::EligibilityChecklist.reset_column_information
    assert checklist_identifier_columns_present?
    assert endpoint_check_constraint_exists?

    checklist.reload
    assert_equal "pr_round_a", checklist.read_attribute(:application_completed_identifier)
    assert_equal "pr_round_b", checklist.read_attribute(:management_approved_identifier)
  end

  test "migrate up aborts with count-only message when a log has a disallowed endpoint" do
    assert_migration_file!
    migrate_silent(:down)
    Corvid::ApiCallLog.reset_column_information
    Corvid::EligibilityChecklist.reset_column_information
    refute endpoint_check_constraint_exists?
    assert checklist_by_columns_present?

    insert_api_call_log_raw!(endpoint: BAD_ENDPOINT)

    error = assert_raises(StandardError) { migrate_silent(:up) }

    refute_includes error.message, BAD_ENDPOINT
    assert_match(/\d+/, error.message)

    Corvid::EligibilityChecklist.reset_column_information
    assert checklist_by_columns_present?
    assert_equal 1, api_call_logs_with_endpoint(BAD_ENDPOINT)
  end

  test "after down then up the endpoint check constraint rejects unknown endpoints" do
    assert_migration_file!
    migrate_silent(:down)
    delete_api_call_logs!

    migrate_silent(:up)
    Corvid::ApiCallLog.reset_column_information
    assert endpoint_check_constraint_exists?

    with_tenant(TENANT) do
      log = Corvid::ApiCallLog.create!(
        tenant_identifier: TENANT,
        api_name: "pas",
        endpoint: "submit",
        called_at: Time.current
      )

      assert_raises(ActiveRecord::CheckViolation) do
        Corvid::ApiCallLog.transaction(requires_new: true) do
          log.update_columns(endpoint: BAD_ENDPOINT)
        end
      end
    end
  end

  private

  def load_bound_endpoint_migration
    paths = Dir[
      Corvid::Engine.root.join("db/migrate/*_bound_endpoint_and_rename_checklist_identifiers.rb").to_s
    ]
    return nil if paths.empty?

    path = paths.first
    require path unless defined?(BoundEndpointAndRenameChecklistIdentifiers)
    BoundEndpointAndRenameChecklistIdentifiers.new
  end

  def assert_migration_file!
    flunk "expected migration file matching *_bound_endpoint_and_rename_checklist_identifiers.rb" unless @migration
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
        application_completed_identifier: application_completed_by,
        management_approved_identifier: management_approved_by
      )
    end
  end

  def checklist_by_columns_present?
    Corvid::EligibilityChecklist.column_names.include?("application_completed_by")
  end

  def checklist_identifier_columns_present?
    Corvid::EligibilityChecklist.column_names.include?("application_completed_identifier")
  end

  def endpoint_check_constraint_exists?
    sql = <<~SQL.squish
      SELECT 1
      FROM pg_constraint c
      INNER JOIN pg_class t ON c.conrelid = t.oid
      WHERE t.relname = 'corvid_api_call_logs'
        AND c.conname = #{ActiveRecord::Base.connection.quote(ENDPOINT_CHECK)}
        AND c.contype = 'c'
      LIMIT 1
    SQL
    ActiveRecord::Base.connection.select_value(sql).present?
  end

  def insert_api_call_log_raw!(endpoint:)
    conn = ActiveRecord::Base.connection
    now = conn.quote(Time.current)
    conn.execute(<<~SQL.squish)
      INSERT INTO corvid_api_call_logs (
        tenant_identifier, api_name, endpoint, called_at, created_at, updated_at
      ) VALUES (
        #{conn.quote(TENANT)}, 'pas', #{conn.quote(endpoint)}, #{now}, #{now}, #{now}
      )
    SQL
  end

  def api_call_logs_with_endpoint(endpoint)
    Corvid::ApiCallLog.unscoped.where(endpoint: endpoint).count
  end

  def delete_api_call_logs!
    Corvid::ApiCallLog.unscoped.delete_all
  end
end
