# frozen_string_literal: true

# Committee review step definitions

Given("the referral has medical priority {int}") do |priority|
  @referral.update!(medical_priority: priority)
end

Then("the referral should require committee review") do
  assert Corvid::CommitteeReview.requires_committee_review?(@referral),
    "Expected referral to require committee review"
end

Then("the referral should not require committee review") do
  refute Corvid::CommitteeReview.requires_committee_review?(@referral),
    "Expected referral to not require committee review"
end

When("I schedule a committee review for {string}") do |date|
  @committee_review = Corvid::CommitteeReview.create!(
    prc_referral: @referral,
    committee_date: Date.parse(date),
    decision: :pending,
    facility_identifier: @facility
  )
end

Given("a pending committee review for {string}") do |date|
  @committee_review = Corvid::CommitteeReview.create!(
    prc_referral: @referral,
    committee_date: Date.parse(date),
    decision: :pending,
    facility_identifier: @facility
  )
end

When("the committee approves with amount {int} by reviewer {string}") do |amount, reviewer|
  @committee_review.update!(
    decision: :approved,
    approved_amount: amount,
    reviewer_identifier: reviewer
  )
end

When("the committee denies with rationale {string} by reviewer {string}") do |rationale, reviewer|
  case_token = @case.id.to_s
  token = Corvid.adapter.store_text(case_token: case_token, kind: :rationale, text: rationale)
  appeal_token = Corvid.adapter.store_text(case_token: case_token, kind: :appeal, text: "Contact PRC office within 30 days")
  @committee_review.update!(
    decision: :denied,
    reviewer_identifier: reviewer,
    rationale_token: token,
    appeal_instructions_token: appeal_token
  )
end

When("the committee defers with rationale {string} by reviewer {string}") do |rationale, reviewer|
  case_token = @case.id.to_s
  token = Corvid.adapter.store_text(case_token: case_token, kind: :rationale, text: rationale)
  @committee_review.update!(
    decision: :deferred,
    reviewer_identifier: reviewer,
    rationale_token: token
  )
end

When("the committee modifies with approved amount {int} from requested {int} by reviewer {string}") do |approved, _requested, reviewer|
  @committee_review.update!(
    decision: :modified,
    approved_amount: approved,
    reviewer_identifier: reviewer
  )
end

When("I add {int} attendees to the committee review") do |count|
  case_token = @case.id.to_s
  attendees = count.times.map { |i| { name: "Attendee #{i + 1}", role: "Member" } }
  token = Corvid.adapter.store_text(case_token: case_token, kind: :attendees, text: attendees)
  @committee_review.update!(attendees_token: token)
end

When("I add {int} documents to the committee review") do |count|
  case_token = @case.id.to_s
  docs = count.times.map { |i| { title: "Document #{i + 1}", type: "Clinical" } }
  token = Corvid.adapter.store_text(case_token: case_token, kind: :documents, text: docs)
  @committee_review.update!(documents_reviewed_token: token)
end

When("I add {int} conditions to the committee review") do |count|
  case_token = @case.id.to_s
  conditions = count.times.map { |i| "Condition #{i + 1}" }
  token = Corvid.adapter.store_text(case_token: case_token, kind: :conditions, text: conditions)
  @committee_review.update!(conditions_token: token)
end

Given("committee reviews scheduled for tomorrow and next week and next month") do
  [1.day.from_now, 5.days.from_now, 35.days.from_now].each_with_index do |date, i|
    Corvid::CommitteeReview.create!(
      prc_referral: @referral,
      committee_date: date.to_date,
      decision: :pending,
      facility_identifier: @facility
    )
  end
end

When("I view upcoming committee reviews for the next {int} days") do |days|
  @upcoming_reviews = Corvid::CommitteeReview.upcoming_reviews(days: days)
end

Then("I should see {int} upcoming reviews") do |count|
  assert_equal count, @upcoming_reviews.count,
    "Expected #{count} upcoming reviews but found #{@upcoming_reviews.count}"
end

Then("a committee review should exist") do
  refute_nil @committee_review
  assert @committee_review.persisted?
end

Then("the committee date should be {string}") do |date|
  assert_equal Date.parse(date), @committee_review.committee_date
end

Then("the committee decision should be {string}") do |decision|
  assert_equal decision, @committee_review.decision
end

Then("the approved amount should be {int}") do |amount|
  assert_equal amount, @committee_review.approved_amount.to_i
end

Then("the appeal deadline should be set") do
  @committee_review.reload
  refute_nil @committee_review.appeal_deadline, "Expected appeal deadline to be set"
end

Then("the review should have {int} attendees") do |count|
  assert_equal count, @committee_review.attendees_count
end

Then("the review should have {int} documents reviewed") do |count|
  assert_equal count, @committee_review.documents_reviewed_count
end

Then("the review should have {int} conditions") do |count|
  assert_equal count, @committee_review.conditions_count
end

Given("a referral in committee review state") do
  @referral.submit!
  @referral.begin_eligibility_review!
  @referral.reload
  checklist = checklist_for(@referral) do |c|
    c.update!(
      application_complete: true, identity_verified: true,
      insurance_verified: true, residency_verified: true,
      enrollment_verified: true, clinical_necessity_documented: true
    )
  end
  @referral.reload
  @referral.request_management_approval!
  @referral.pending_approval_by = "pr_test_mgr"
  @referral.approve_management!
  @referral.verify_alternate_resources!
  @referral.update!(estimated_cost: 100_000)
  @referral.complete_priority_assignment!
  assert_equal "committee_review", @referral.status
end

When("the decision is applied to the referral") do
  @committee_review.apply_to_referral!
  @referral.reload
end

# "the referral should be authorized" — unique to this file
Then("the referral should be authorized") do
  @referral.reload
  assert_equal "authorized", @referral.status
end

# "the referral should be denied" is defined in notification_rules_steps.rb
# Do not redefine here to avoid Cucumber::Ambiguous
