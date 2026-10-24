# frozen_string_literal: true

# Issue #702 / ADR 0001: the PRC check reference is an opaque external
# identifier. Rename in place so existing values are kept.
class RenameCheckNumberToCheckIdentifierOnCorvidPrcPayments < ActiveRecord::Migration[8.1]
  def change
    rename_column :corvid_prc_payments, :check_number, :check_identifier
  end
end
