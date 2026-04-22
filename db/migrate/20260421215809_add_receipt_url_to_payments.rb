# frozen_string_literal: true

class AddReceiptUrlToPayments < ActiveRecord::Migration[8.1]
  def change
    add_column :corvid_payments, :receipt_url, :string
  end
end
