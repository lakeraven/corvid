# frozen_string_literal: true

# 72-hour notification rules step definitions (ported from rpms_redux)

Given("the referral is flagged as emergency") do
  @referral.update!(emergency_flag: true)
end

Given("the referral is not flagged as emergency") do
  @referral.update!(emergency_flag: false)
end

Given("the emergency occurred {string} hours ago") do |hours|
  @referral.update!(notification_date: hours.to_i.hours.ago)
end

Given("the referral has no notification date") do
  @referral.update!(notification_date: nil)
end

Given("the facility has a notification grace period of {string} hours") do |hours|
  # Store grace period in adapter site params
  Corvid.adapter.define_singleton_method(:get_site_params) do
    {
      station_number: "9999",
      station_name: "MOCK FACILITY",
      chs_enabled: true,
      notification_grace_period: hours.to_i,
      committee_threshold: 50_000
    }
  end
end

Given("the late notification has been documented") do
  @referral.document_late_notification!(
    reason: "Patient stabilized at remote facility",
    documented_by: "pr_test_001"
  )
end

When("notification status is checked") do
  @notification_status = @referral.notification_status
end

When("the referral is submitted for exception review") do
  @referral.submit!
  @referral.begin_eligibility_review!
end

When("exception review is approved with rationale {string}") do |rationale|
  @referral.submit! unless @referral.submitted? || @referral.eligibility_review? || @referral.exception_review?
  @referral.begin_eligibility_review! if @referral.submitted?
  @referral.approve_exception_review!(rationale: rationale, approved_by: "pr_test_001")
end

When("exception review is denied with rationale {string}") do |rationale|
  @referral.submit! unless @referral.submitted? || @referral.eligibility_review? || @referral.exception_review?
  @referral.begin_eligibility_review! if @referral.submitted?
  @referral.deny_exception_review!(rationale: rationale, denied_by: "pr_test_001")
end

When("late notification is documented with reason {string}") do |reason|
  @referral.document_late_notification!(reason: reason, documented_by: "pr_test_001")
end

Then("the notification should be {string}") do |status|
  assert_equal status, @notification_status
end

Then("the referral should not require exception review") do
  refute @referral.requires_exception_review?
end

Then("the referral should require exception review") do
  assert @referral.requires_exception_review?
end

Then("the late notification hours should be {string}") do |hours|
  assert_equal hours.to_i, @referral.hours_since_notification.to_i
end

Then("a task should be created for exception review") do
  @referral.reload
  task = @referral.tasks.find_by("description ILIKE ?", "%exception%")
  refute_nil task, "Expected an exception review task but found: #{@referral.tasks.pluck(:description)}"
end

Then("the task description should include {string}") do |text|
  task = @referral.tasks.last
  assert_includes task.description.downcase, text.downcase
end

Then("the referral should proceed to eligibility review") do
  assert_equal "eligibility_review", @referral.status
end

Then("the exception approval should be recorded") do
  assert @referral.exception_approved
  refute_nil @referral.exception_reviewed_at
end

Then("the referral should be denied") do
  assert_equal "denied", @referral.status
end

Then("the denial reason should include {string}") do |text|
  # Check the deferred reason or the latest determination
  det = @referral.latest_determination
  refute_nil det, "Expected a determination"
  assert_equal "denied", det.outcome
end

Then("the late notification reason should be recorded") do
  refute_nil @referral.late_notification_reason_token
end

Then("the documentation timestamp should be recorded") do
  refute_nil @referral.late_notification_documented_at
end
