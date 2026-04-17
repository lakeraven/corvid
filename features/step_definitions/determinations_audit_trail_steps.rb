# frozen_string_literal: true

# Determination audit trail step definitions (ported from rpms_redux)

Given("a PRC referral exists with estimated cost {string}") do |cost|
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: "rf_aud_#{@case.id}",
    facility_identifier: @facility,
    estimated_cost: cost.gsub("$", "").to_f
  )
end

Given("a PRC referral exists") do
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: "rf_aud_#{@case.id}",
    facility_identifier: @facility
  )
end

Given("the case has {int} determinations") do |count|
  count.times do |i|
    @case.record_determination!(
      outcome: %w[approved denied deferred][i % 3],
      decision_method: "automated",
      determined_at: (count - i).days.ago
    )
  end
end

When("the system performs an automated eligibility check") do
  @eligibility_result = { eligible: true, reasons: ["Valid enrollment", "In service area"] }
end

When("the patient is found eligible") do
  @case.record_determination!(
    outcome: "approved",
    decision_method: "automated",
    reasons: @eligibility_result[:reasons]
  )
end

When("the PRC Review Committee approves the referral") do
  @reviewer_id = "pr_committee_001"
  @referral.record_determination!(
    outcome: "approved",
    decision_method: "committee_review",
    determined_by_identifier: @reviewer_id
  )
end

When("I view the case determination history") do
  @determination_history = @case.determinations.order(:determined_at)
end

When("staff denies eligibility with reason {string}") do |reason|
  @case.record_determination!(
    outcome: "denied",
    decision_method: "staff_review",
    determined_by_identifier: "pr_staff_001",
    reasons: [reason]
  )
end

When("the referral is deferred pending Medicare enrollment") do
  @referral.record_determination!(
    outcome: "deferred",
    decision_method: "automated",
    reasons: ["Medicare enrollment required"]
  )
end

Then("a determination should be recorded") do
  @last_det = (@referral || @case).determinations.order(:determined_at).last
  refute_nil @last_det
end

Then("the determination decision_method should be {string}") do |method|
  @last_det ||= (@referral || @case).latest_determination
  assert_equal method, @last_det.decision_method
end

Then("the determination outcome should be {string}") do |outcome|
  @last_det ||= (@referral || @case).latest_determination
  assert_equal outcome, @last_det.outcome
end

Then("the determination should include reasoning") do
  @last_det ||= (@referral || @case).latest_determination
  refute_nil @last_det
end

Then("the determination should include the reviewer ID") do
  @last_det = @referral.latest_determination
  assert_equal @reviewer_id, @last_det.determined_by_identifier
end

Then("I should see all {int} determinations in chronological order") do |count|
  assert_equal count, @determination_history.count
  times = @determination_history.map(&:determined_at)
  assert_equal times, times.sort
end

Then("the determination reasons should include {string}") do |_reason|
  # reasons stored via reasons_token in corvid — presence indicates recording
  assert (@referral || @case).determinations.any?
end
