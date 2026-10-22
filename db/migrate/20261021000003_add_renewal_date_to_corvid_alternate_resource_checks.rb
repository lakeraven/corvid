# frozen_string_literal: true

# Issue #640: store the renewal date an eligibility response reports so a
# later date of service can tell whether that determination still applies.
class AddRenewalDateToCorvidAlternateResourceChecks < ActiveRecord::Migration[8.1]
  def change
    add_column :corvid_alternate_resource_checks, :renewal_date, :date
  end
end
