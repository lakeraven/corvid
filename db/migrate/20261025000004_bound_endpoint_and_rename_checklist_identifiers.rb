# frozen_string_literal: true

# CMS-0057-F counts calls by route name. A free-text endpoint can hold a
# request path, and a path can carry a patient identifier, so the column is
# pinned to the route-name vocabulary. Rows already outside that list are
# counted first. The migration raises with the count alone and changes
# nothing until the count is zero — the values stay in the table and out of
# the error.
#
# The checklist approver columns were named *_by. ADR 0001 names an opaque
# external reference *_identifier. verify_item!'s by: keyword is unchanged.
class BoundEndpointAndRenameChecklistIdentifiers < ActiveRecord::Migration[8.1]
  # Frozen here and not read from Corvid::ApiCallLog. The model constant
  # mirrors this list; the constraint must not follow application code.
  ENDPOINTS = %w[submit read search covered_services documentation].freeze
  ENDPOINT_CHECK = "corvid_api_call_logs_endpoint_check"

  def up
    refuse_disallowed_endpoints!
    add_endpoint_check
    rename_column :corvid_eligibility_checklists, :application_completed_by, :application_completed_identifier
    rename_column :corvid_eligibility_checklists, :management_approved_by, :management_approved_identifier
  end

  def down
    rename_column :corvid_eligibility_checklists, :application_completed_identifier, :application_completed_by
    rename_column :corvid_eligibility_checklists, :management_approved_identifier, :management_approved_by
    remove_check_constraint :corvid_api_call_logs, name: ENDPOINT_CHECK
  end

  private

  def refuse_disallowed_endpoints!
    count = disallowed_endpoint_count
    return if count.zero?

    raise "#{count} corvid_api_call_logs rows have an endpoint outside the allowed list"
  end

  def disallowed_endpoint_count
    list = ENDPOINTS.map { |name| connection.quote(name) }.join(",")
    connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM corvid_api_call_logs WHERE endpoint NOT IN (#{list})
    SQL
  end

  def add_endpoint_check
    list = ENDPOINTS.map { |name| "'#{name}'" }.join(",")
    add_check_constraint :corvid_api_call_logs,
      "endpoint IN (#{list})",
      name: ENDPOINT_CHECK
  end
end
