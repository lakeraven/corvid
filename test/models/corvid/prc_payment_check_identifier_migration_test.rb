# frozen_string_literal: true

require "test_helper"

# Issue #702: check_number becomes check_identifier on corvid_prc_payments via a
# reversible rename migration. Values must survive up and down.
class PrcPaymentCheckIdentifierMigrationTest < ActiveSupport::TestCase
  TENANT = "tnt_prc_payment_chk_id_migrate"
  CHECK_VALUE = "CHK-MIGRATE-PRESERVE"

  MIGRATION_GLOB = File.join(
    Corvid::Engine.root.to_s,
    "db/migrate/*_rename_check_number_to_check_identifier_on_corvid_prc_payments.rb"
  )

  def migration_paths
    Dir[MIGRATION_GLOB]
  end

  def require_rename_migration!
    paths = migration_paths
    flunk "expected migration file matching #{MIGRATION_GLOB}" if paths.empty?

    path = paths.first
    require path unless defined?(RenameCheckNumberToCheckIdentifierOnCorvidPrcPayments)
    RenameCheckNumberToCheckIdentifierOnCorvidPrcPayments.new
  end

  test "rename migration preserves existing check values up and down" do
    migration = require_rename_migration!

    with_tenant(TENANT) do
      obligation = Corvid::PrcObligation.create!(
        facility_identifier: "SEA",
        obligation_id: "OBL-MIGRATE-CHK",
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
        payment_id: "PMT-MIGRATE-CHK",
        paid_date: Date.new(2009, 6, 15),
        check_identifier: CHECK_VALUE,
        amount_cents: 10_000,
        vendor_name: "CLINIC"
      )

      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
      Corvid::PrcPayment.reset_column_information

      payment.reload
      assert_equal CHECK_VALUE, payment.check_number
      refute_includes Corvid::PrcPayment.column_names, "check_identifier"

      ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      Corvid::PrcPayment.reset_column_information

      payment.reload
      assert_equal CHECK_VALUE, payment.check_identifier
      refute_includes Corvid::PrcPayment.column_names, "check_number"
    end
  ensure
    if defined?(RenameCheckNumberToCheckIdentifierOnCorvidPrcPayments)
      conn = Corvid::PrcPayment.connection
      unless conn.column_exists?(:corvid_prc_payments, :check_identifier)
        ActiveRecord::Migration.suppress_messages do
          RenameCheckNumberToCheckIdentifierOnCorvidPrcPayments.new.migrate(:up)
        end
      end
    end
    Corvid::PrcPayment.reset_column_information
  end
end
