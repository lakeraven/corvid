# frozen_string_literal: true

require "test_helper"

# Issue #702: patient PHI must not be persisted on corvid_prc_payments.
# The cheque reference is dropped via a reversible migration; down re-adds an
# empty nullable check_number column (values cannot be restored).
class PrcPaymentDropCheckNumberMigrationTest < ActiveSupport::TestCase
  TENANT = "tnt_prc_payment_drop_chk_migrate"

  MIGRATION_GLOB = File.join(
    Corvid::Engine.root.to_s,
    "db/migrate/*_remove_check_number_from_corvid_prc_payments.rb"
  )

  def migration_paths
    Dir[MIGRATION_GLOB]
  end

  def require_remove_migration!
    paths = migration_paths
    flunk "expected migration file matching #{MIGRATION_GLOB}" if paths.empty?

    path = paths.first
    require path unless defined?(RemoveCheckNumberFromCorvidPrcPayments)
    RemoveCheckNumberFromCorvidPrcPayments.new
  end

  test "remove check_number migration down adds empty column and up drops it" do
    migration = require_remove_migration!

    with_tenant(TENANT) do
      obligation = Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-MIGRATE-DROP-CHK",
        vendor_id: "VEND1",
        procedure_code: "OFFICE_VISIT_EST",
        service_date: Date.new(2009, 5, 4),
        status: "A",
        billed_amount: 100,
        paid_amount: 100,
        savings: 0,
        balance: 0,
        fiscal_year: 2009,
        source_file: "migrate_test.prc",
        imported_at: Time.current
      )
      payment = Corvid::PrcPayment.create!(
        prc_obligation: obligation,
        payment_id: "PMT-MIGRATE-DROP-CHK",
        paid_date: Date.new(2009, 6, 15),
        amount_cents: 10_000,
        vendor_name: "CLINIC"
      )

      refute_includes Corvid::PrcPayment.column_names, "check_number"
      refute_includes Corvid::PrcPayment.column_names, "check_identifier"

      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
      Corvid::PrcPayment.reset_column_information

      assert_includes Corvid::PrcPayment.column_names, "check_number"
      col = Corvid::PrcPayment.columns_hash["check_number"]
      assert col.null, "check_number must be nullable after migrate down"
      assert_equal :string, col.type

      payment.reload
      assert_nil payment.check_number

      ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      Corvid::PrcPayment.reset_column_information

      refute_includes Corvid::PrcPayment.column_names, "check_number"
      refute_includes Corvid::PrcPayment.column_names, "check_identifier"
    end
  ensure
    if defined?(RemoveCheckNumberFromCorvidPrcPayments)
      conn = Corvid::PrcPayment.connection
      if conn.column_exists?(:corvid_prc_payments, :check_number)
        ActiveRecord::Migration.suppress_messages do
          RemoveCheckNumberFromCorvidPrcPayments.new.migrate(:up)
        end
      end
    end
    Corvid::PrcPayment.reset_column_information
  end
end
