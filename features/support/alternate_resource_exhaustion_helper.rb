# frozen_string_literal: true

# Seeds all 12 alternate-resource check rows as exhausted (not_enrolled) so
# guarded authorization transitions can fire in workflow tests.
def exhaust_alternate_resources!(referral)
  Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
    referral.alternate_resource_checks.find_or_create_by!(resource_type: type) do |check|
      check.status = "not_enrolled"
    end
  end
  referral.alternate_resource_checks.reload
end
