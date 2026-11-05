# frozen_string_literal: true

# Issue #372: each analysis row records the CMS wage area and the
# ZIP→CBSA crosswalk release used to price an institutional claim.
# wage_area is NULL (professional / unmapped), "NATIONAL", or a
# ZipCbsaCrosswalk CBSA (five digits or a two-digit rural-state code).
# The expression is the form pg_get_constraintdef pretty-prints, the
# same spelling as the other string CHECKs in schema.rb, so a migrate
# and a schema load store one definition. The facility ZIP is not a
# column (ADR 0003).
class AddWageAreaProvenanceToCorvidPrcOverpaymentAnalyses < ActiveRecord::Migration[8.1]
  WAGE_AREA_CHECK = "corvid_prc_overpayment_analyses_wage_area_check"
  WAGE_AREA_SQL = "wage_area IS NULL OR wage_area::text = 'NATIONAL'::text " \
                  "OR wage_area::text ~ '^([0-9]{5}|[0-9]{2})$'::text"

  def change
    add_column :corvid_prc_overpayment_analyses, :wage_area, :string
    add_column :corvid_prc_overpayment_analyses, :crosswalk_release, :string
    add_check_constraint :corvid_prc_overpayment_analyses, WAGE_AREA_SQL, name: WAGE_AREA_CHECK
  end
end
