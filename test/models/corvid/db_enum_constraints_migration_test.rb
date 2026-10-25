# frozen_string_literal: true

require "test_helper"

module Corvid
  # Reversible migration spec for AddDbConstraintsForUnboundedEnumColumns (#704).
  class DbEnumConstraintsMigrationTest < ActiveSupport::TestCase
    TENANT = "tnt_db_enum_migration"

    teardown do
      restore_constraints_up_state!
    end

    test "migrate down drops enum constraints and restores closure_reason" do
      migration = require_constraints_migration!

      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }

      referral = nil
      with_tenant(TENANT) do
        referral = create_prc_referral!
        assert_db_accepts_update(referral, priority_system: "legacy_unconstrained")
      end

      assert_includes Case.column_names, "closure_reason",
                      "migrate down should restore the dropped closure_reason column"
    end

    test "migrate up re-applies enum constraints" do
      migration = require_constraints_migration!

      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
      ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }

      with_tenant(TENANT) do
        referral = create_prc_referral!
        assert_db_rejects_update(referral, priority_system: "legacy_unconstrained")
      end

      refute_includes Case.column_names, "closure_reason",
                      "migrate up should drop closure_reason again"
    end

    test "migrate up fails loudly when existing rows violate new constraints" do
      migration = require_constraints_migration!

      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }

      with_tenant(TENANT) do
        referral = create_prc_referral!
        assert_db_accepts_update(referral, priority_system: "legacy_unconstrained")
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      end

      with_tenant(TENANT) do
        referral = PrcReferral.order(:id).last
        assert_equal "legacy_unconstrained", referral.priority_system,
                     "migrate up must not coerce violating data"
      end
    end

    private

    def constraints_migration_paths
      Dir[
        Rails.root.join("db/migrate/*_add_db_constraints_for_unbounded_enum_columns.rb").to_s,
        Corvid::Engine.root.join("db/migrate/*_add_db_constraints_for_unbounded_enum_columns.rb").to_s
      ]
    end

    def require_constraints_migration!
      paths = constraints_migration_paths
      flunk "expected migration file matching *_add_db_constraints_for_unbounded_enum_columns.rb" if paths.empty?

      path = paths.first
      require path unless defined?(AddDbConstraintsForUnboundedEnumColumns)
      AddDbConstraintsForUnboundedEnumColumns.new
    end

    def restore_constraints_up_state!
      return if constraints_migration_paths.empty?
      return unless defined?(AddDbConstraintsForUnboundedEnumColumns)

      ActiveRecord::Migration.suppress_messages do
        AddDbConstraintsForUnboundedEnumColumns.new.migrate(:up)
      end
      reset_column_information!
    end

    def reset_column_information!
      [
        Case, PrcReferral, PrcEligibilityDecision, PrcObligation, PrcOverpaymentAnalysis,
        CareTeamMember, ClaimSubmission, FmapDetermination
      ].each(&:reset_column_information!)
    end

    def assert_db_rejects_update(record, attrs)
      assert_raises(ActiveRecord::StatementInvalid) do
        record.class.transaction(requires_new: true) do
          record.update_columns(attrs)
        end
      end
    end

    def assert_db_accepts_update(record, attrs)
      record.class.transaction(requires_new: true) do
        record.update_columns(attrs)
      end
      record.reload
    end

    def create_prc_referral!
      kase = Case.create!(patient_identifier: "pt_mig_#{SecureRandom.hex(3)}", facility_identifier: "fac_mig")
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_mig_#{SecureRandom.hex(4)}",
        facility_identifier: "fac_mig"
      )
    end
  end
end
