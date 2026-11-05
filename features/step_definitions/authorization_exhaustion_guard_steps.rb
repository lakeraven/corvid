# frozen_string_literal: true

When("the Referral Specialist attempts to verify alternate resources") do
  @verify_alternate_resources_result = @referral.verify_alternate_resources!
  @referral.reload
end

Then("the referral should show authorization blocker {string}") do |blocker|
  blockers = @referral.authorization_blockers
  assert_includes blockers, blocker,
    "expected blocker #{blocker.inspect}, got #{blockers.inspect}"
end

When("the alternate resource check for {string} is set to {string}") do |resource_type, status|
  check = @referral.alternate_resource_checks.find_by!(resource_type: resource_type)
  check.update!(status: status)
  stamp_alternate_resource_check_current!(check) unless %w[not_checked checking].include?(status)
  @referral.reload
end

Given("today's date is {string}") do |iso_date|
  @frozen_time = Time.zone.parse("#{iso_date} 12:00:00 UTC")
  travel_to @frozen_time
end

Given("all twelve alternate resource checks are current except {string} verified {int} days ago") do |resource_type, days|
  exhaust_alternate_resources!(@referral, date_of_service: @frozen_time.to_date, as_of: @frozen_time)
  check = @referral.alternate_resource_checks.find_by!(resource_type: resource_type)
  check.update!(checked_at: @frozen_time - days.days)
end

Given("the adapter confirms {string} as not enrolled when re-verified") do |resource_type|
  patient_id = @referral.case.patient_identifier
  @reverified_types = []
  reverified = @reverified_types
  Corvid.adapter.define_singleton_method(:verify_eligibility) do |pid, type, date_of_service: nil|
    reverified << type if pid == patient_id && type == resource_type
    echo_verify_eligibility_date({ eligible: false }, date_of_service)
  end
end

Then("{string} eligibility should have been re-verified for patient {string}") do |resource_type, patient_id|
  assert_equal patient_id, @referral.case.patient_identifier
  assert_includes @reverified_types, resource_type,
    "expected re-verification of #{resource_type}, got #{@reverified_types.inspect}"
end
