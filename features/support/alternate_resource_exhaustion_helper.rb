# frozen_string_literal: true

# Seeds all 12 alternate-resource check rows as exhausted (not_enrolled) so
# guarded authorization transitions can fire in workflow tests.
#
# Issue #668: each row is stamped current for Date.current so authorization
# and claim gates that require fresh determinations can pass in fixtures.
def exhaust_alternate_resources!(referral, date_of_service: Date.current, as_of: Time.current)
  Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
    check = referral.alternate_resource_checks.find_or_create_by!(resource_type: type) do |row|
      row.status = "not_enrolled"
    end
    check.update!(status: "not_enrolled")
    stamp_alternate_resource_check_current!(check, date_of_service: date_of_service, as_of: as_of)
  end
  referral.alternate_resource_checks.reload
end

# Makes a persisted check current_for?(date_of_service, as_of:) per issue #640 / #668.
def stamp_alternate_resource_check_current!(check, date_of_service: Date.current, as_of: Time.current)
  return if check.not_checked? || check.checking?

  attrs = { checked_at: as_of }

  if check.has_coverage?
    attrs[:coverage_start] = date_of_service - 30.days
    attrs[:coverage_end] = date_of_service + 30.days
    attrs[:renewal_date] = date_of_service + 60.days unless check.coordinated?
  elsif (check.exhausted? || check.denied?) &&
      (check.coverage_start.present? || check.coverage_end.present?)
    attrs[:coverage_start] = check.coverage_start || (date_of_service - 30.days)
    attrs[:coverage_end] = check.coverage_end || (date_of_service + 30.days)
    attrs[:renewal_date] = check.renewal_date || (date_of_service + 60.days)
  else
    attrs[:coverage_start] = nil
    attrs[:coverage_end] = nil
    attrs[:renewal_date] = nil
  end

  if month_bounded_alternate_resource_type?(check.resource_type)
    attrs[:inquiry_date_of_service] = date_of_service
  end

  check.update!(attrs)
end

# Re-stamp all checks for a claim's service date so month-bounded Medicaid
# answers match the date claim submission gates judge (issue #712).
def stamp_alternate_resources_for_claim_service_date!(referral, service_date, as_of: Time.current)
  exhaust_alternate_resources!(referral, date_of_service: service_date, as_of: as_of)
end

def month_bounded_alternate_resource_type?(resource_type)
  return true if resource_type.to_s.casecmp("medicaid").zero?

  types = Corvid.configuration.month_bounded_eligibility_resource_types
  return false unless types.is_a?(Array)

  types.any? { |type| type.to_s.casecmp(resource_type.to_s).zero? }
end

def echo_verify_eligibility_date(result, date_of_service)
  return result unless date_of_service.instance_of?(Date)
  return result unless result.is_a?(Hash)
  return result unless result[:eligible] == true || result[:eligible] == false

  result.merge(date_of_service: date_of_service, date_of_service_defaulted: false)
end
