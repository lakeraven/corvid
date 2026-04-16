# frozen_string_literal: true

# Article 6 reimbursement step definitions (ported from rpms_redux)

Given("there are paid claim submissions in the system") do
  3.times do |i|
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_#{i}",
      claim_reference: "CLM_ART6_#{i}",
      claim_type: "professional",
      status: "paid",
      billed_amount: 500.00 + (i * 100),
      paid_amount: 400.00 + (i * 80),
      paid_date: Date.current - i.days,
      service_date: Date.current - (i + 5).days,
      provider_identifier: "pr_art6_#{i % 2}",
      state_share: (400.00 + (i * 80)) * 0.5,
      county_share: (400.00 + (i * 80)) * 0.5,
      submitted_at: (i + 10).days.ago
    )
  end
end

When("I generate an Article 6 summary report for the current quarter") do
  quarter_start = Date.current.beginning_of_quarter
  quarter_end = Date.current.end_of_quarter
  claims = Corvid::ClaimSubmission.paid.in_date_range(quarter_start..quarter_end)
  @report = {
    period: "#{quarter_start} to #{quarter_end}",
    total_claims: claims.count,
    total_billed: claims.sum(:billed_amount),
    total_paid: claims.sum(:paid_amount),
    total_state_share: claims.sum(:state_share),
    total_county_share: claims.sum(:county_share),
    by_provider: claims.group(:provider_identifier).sum(:paid_amount)
  }
end

When("I export the report as CSV") do
  @csv_lines = []
  @csv_lines << "Provider,Paid Amount,State Share,County Share"
  claims = Corvid::ClaimSubmission.paid
  claims.group(:provider_identifier).each do |provider, _|
    provider_claims = claims.where(provider_identifier: provider)
    @csv_lines << "#{provider},#{provider_claims.sum(:paid_amount)},#{provider_claims.sum(:state_share)},#{provider_claims.sum(:county_share)}"
  end
end

Then("I should see the total reimbursement amount") do
  assert @report[:total_paid] > 0
end

Then("I should see claims grouped by provider") do
  assert @report[:by_provider].keys.length > 0
end

Then("I should see claims grouped by quarter") do
  refute_nil @report[:period]
end

Then("I should see the state and county share breakdown") do
  assert @report[:total_state_share] > 0 || @report[:total_county_share] > 0
end

Then("the CSV should contain the report data") do
  assert @csv_lines.length > 1
  assert @csv_lines.first.include?("Provider")
end
