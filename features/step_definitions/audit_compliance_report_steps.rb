# frozen_string_literal: true

def create_referral_with_checklist(index, overrides = {})
  kase = Corvid::Case.create!(
    patient_identifier: "pt_audit_#{index}",
    facility_identifier: @facility
  )
  referral = Corvid::PrcReferral.create!(
    case: kase,
    referral_identifier: "rf_audit_#{index}",
    facility_identifier: @facility
  )
  defaults = {
    application_complete: true,
    identity_verified: true,
    insurance_verified: true,
    residency_verified: true,
    enrollment_verified: true,
    clinical_necessity_documented: true,
    management_approved: true
  }
  Corvid::EligibilityChecklist.create!(
    prc_referral: referral,
    facility_identifier: @facility,
    **defaults.merge(overrides)
  )
  referral
end

Given("{int} PRC referrals with complete eligibility checklists") do |count|
  @audit_offset ||= 0
  count.times do |i|
    create_referral_with_checklist(@audit_offset + i)
  end
  @audit_offset += count
end

Given("{int} PRC referrals missing management approval") do |count|
  count.times do |i|
    create_referral_with_checklist(@audit_offset + i, management_approved: false)
  end
  @audit_offset += count
end

Given("{int} PRC referrals missing identity verification") do |count|
  count.times do |i|
    create_referral_with_checklist(@audit_offset + i, identity_verified: false)
  end
  @audit_offset += count
end

When("I generate the compliance summary") do
  @summary = Corvid::PrcAuditReportService.compliance_summary(tenant: @tenant)
end

When("I generate the deficiency report") do
  @deficiencies = Corvid::PrcAuditReportService.deficiency_report(tenant: @tenant)
end

When("I run a sample audit of {int} referrals") do |sample_size|
  @audit_result = Corvid::PrcAuditReportService.sample_audit(tenant: @tenant, sample_size: sample_size)
end

Then("every audit category should show 100% compliance") do
  Corvid::EligibilityChecklist::ITEMS.each do |item|
    assert_equal 100.0, @summary[item][:percentage],
      "Expected #{item} to be 100% but was #{@summary[item][:percentage]}%"
  end
end

Then("the total referrals should be {int}") do |count|
  assert_equal count, @summary[:total_referrals]
end

Then("{int} referrals should appear in the deficiency report") do |count|
  assert_equal count, @deficiencies.size
end

Then("each deficient referral should list {string} as missing") do |item|
  @deficiencies.each do |deficiency|
    assert_includes deficiency[:missing_items], item.to_sym,
      "Expected #{item} in missing items for referral #{deficiency[:referral_identifier]}"
  end
end

Then("the sample audit should show {int} of {int} with complete applications") do |pass, total|
  assert_equal pass, @audit_result[:application_complete][:passed]
  assert_equal total, @audit_result[:application_complete][:sampled]
end

Then("the sample audit should show {int} of {int} with identity documentation") do |pass, total|
  assert_equal pass, @audit_result[:identity_verified][:passed]
  assert_equal total, @audit_result[:identity_verified][:sampled]
end

Then("the sample audit should show {int} of {int} with insurance verification") do |pass, total|
  assert_equal pass, @audit_result[:insurance_verified][:passed]
  assert_equal total, @audit_result[:insurance_verified][:sampled]
end

Then("the sample audit should show {int} of {int} with residency verification") do |pass, total|
  assert_equal pass, @audit_result[:residency_verified][:passed]
  assert_equal total, @audit_result[:residency_verified][:sampled]
end

Then("the sample audit should show {int} of {int} with tribal enrollment") do |pass, total|
  assert_equal pass, @audit_result[:enrollment_verified][:passed]
  assert_equal total, @audit_result[:enrollment_verified][:sampled]
end

Then("the sample audit should show {int} of {int} with management approval") do |pass, total|
  assert_equal pass, @audit_result[:management_approved][:passed]
  assert_equal total, @audit_result[:management_approved][:sampled]
end
