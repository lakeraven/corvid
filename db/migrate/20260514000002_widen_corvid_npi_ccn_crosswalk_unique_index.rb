# frozen_string_literal: true

# Forward migration for environments that already ran
# CreateCorvidNpiCcnCrosswalks with the original unique index
# (npi, ccn, effective_date). We now allow multiple snapshots to
# coexist by scoping uniqueness to source_release as well.
class WidenCorvidNpiCcnCrosswalkUniqueIndex < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_corvid_npi_ccn_crosswalks_unique"
  TABLE_NAME = :corvid_npi_ccn_crosswalks

  def up
    # Drop whichever version currently exists under this canonical name.
    remove_index TABLE_NAME, name: INDEX_NAME if index_name_exists?(TABLE_NAME, INDEX_NAME)

    add_index TABLE_NAME, [ :source_release, :npi, :ccn, :effective_date ],
              unique: true, name: INDEX_NAME
  end

  def down
    remove_index TABLE_NAME, name: INDEX_NAME if index_name_exists?(TABLE_NAME, INDEX_NAME)

    add_index TABLE_NAME, [ :npi, :ccn, :effective_date ],
              unique: true, name: INDEX_NAME
  end
end
