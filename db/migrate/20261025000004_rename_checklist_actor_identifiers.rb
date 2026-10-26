# frozen_string_literal: true

# The checklist actor columns were named *_by. ADR 0001 names an opaque
# external reference *_identifier, so these become *_by_identifier.
# verify_item!'s by: keyword is unchanged.
class RenameChecklistActorIdentifiers < ActiveRecord::Migration[8.1]
  def up
    rename_column :corvid_eligibility_checklists, :application_completed_by, :application_completed_by_identifier
    rename_column :corvid_eligibility_checklists, :management_approved_by, :management_approved_by_identifier
  end

  def down
    rename_column :corvid_eligibility_checklists, :application_completed_by_identifier, :application_completed_by
    rename_column :corvid_eligibility_checklists, :management_approved_by_identifier, :management_approved_by
  end
end
