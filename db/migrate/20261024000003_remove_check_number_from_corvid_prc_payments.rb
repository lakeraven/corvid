# frozen_string_literal: true

# check_number is patient PHI per the #591 disclosure, whose remediation is
# to stop persisting it. The column is removed. A rollback re-adds an empty
# nullable string and cannot restore the values.
class RemoveCheckNumberFromCorvidPrcPayments < ActiveRecord::Migration[8.1]
  def change
    remove_column :corvid_prc_payments, :check_number, :string
  end
end
