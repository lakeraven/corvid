# frozen_string_literal: true

# Issue #712: the date of service an eligibility inquiry answered for.
# Month-scoped coverage (Medicaid) is current only in that year-month.
class AddInquiryDateOfServiceToAlternateResourceChecks < ActiveRecord::Migration[8.1]
  def change
    add_column :corvid_alternate_resource_checks, :inquiry_date_of_service, :date
  end
end
