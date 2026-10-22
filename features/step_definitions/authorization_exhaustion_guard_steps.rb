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
  @referral.reload
end
