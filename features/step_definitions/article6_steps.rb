# frozen_string_literal: true

# Article 6 reimbursement step definitions (ported from the predecessor app)

Given("there are paid claim submissions in the system") do
  3.times do |i|
    service_date = [ Date.current - (i + 5).days, Date.current.beginning_of_quarter ].max
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_#{i}",
      claim_identifier: "CLM_ART6_#{i}",
      claim_type: "professional",
      status: "paid",
      billed_amount: 500.00 + (i * 100),
      paid_amount: 400.00 + (i * 80),
      # Both dates are clamped into the current quarter, and paid_date is never
      # before service_date.
      #
      # WHY: the report filters on service_date (ClaimSubmission.in_date_range).
      # An UNCLAMPED `Date.current - (i + 5).days` falls in the previous quarter
      # during a quarter's first week -- of the three claims none were in-window
      # on days 1-5, one on day 6, two on day 7 -- so the report summed less than
      # the suite expected. Green 2026-09-26, red 2026-10-01. With the clamp all
      # three are always in-window; the decoys below are what keep the filter
      # itself under test.
      service_date: service_date,
      paid_date: [ Date.current - i.days, service_date ].max,
      provider_identifier: "pr_art6_#{i % 2}",
      state_share: (400.00 + (i * 80)) * 0.5,
      county_share: (400.00 + (i * 80)) * 0.5,
      submitted_at: (i + 10).days.ago
    )
  end

  # Two decoys OUTSIDE the current quarter, so the report's service_date window
  # is observable in BOTH directions. Without them every seeded claim is
  # in-window by construction and the suite passes with `in_date_range` deleted.
  #
  # The early decoy's paid_date is deliberately in the CURRENT quarter while its
  # service_date is in the previous one: that is what catches a report filtering
  # the wrong COLUMN (paid_date instead of service_date), which a decoy with both
  # dates in the past cannot catch. The late decoy catches a missing upper bound.
  [
    { suffix: "early", service_date: Date.current.beginning_of_quarter - 10.days,
      paid_date: Date.current, billed: 999.00, paid: 777.00 },
    { suffix: "late", service_date: Date.current.end_of_quarter + 10.days,
      paid_date: Date.current.end_of_quarter + 10.days, billed: 888.00, paid: 666.00 }
  ].each do |decoy|
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_decoy_#{decoy[:suffix]}",
      claim_identifier: "CLM_ART6_DECOY_#{decoy[:suffix].upcase}",
      claim_type: "professional",
      status: "paid",
      billed_amount: decoy[:billed],
      paid_amount: decoy[:paid],
      paid_date: decoy[:paid_date],
      service_date: decoy[:service_date],
      provider_identifier: "pr_art6_decoy_#{decoy[:suffix]}",
      state_share: decoy[:paid] / 2,
      county_share: decoy[:paid] / 2,
      submitted_at: 40.days.ago
    )
  end
end

When("I generate an Article 6 summary report for the current quarter") do
  quarter_start = Date.current.beginning_of_quarter
  quarter_end = Date.current.end_of_quarter
  claims = Corvid::ClaimSubmission.paid.in_date_range(quarter_start..quarter_end)
  # Article 6 is US-domestic state/county Medicaid reimbursement so
  # cents → dollars is unambiguous here. For multi-currency tenants the
  # production report path (e.g., PrcOverpaymentReportService) uses
  # money-rails' per-currency bucketing instead.
  to_dollars = ->(cents) { (cents || 0) / 100.0 }
  @report = {
    period: "#{quarter_start} to #{quarter_end}",
    total_claims: claims.count,
    total_billed: to_dollars[claims.sum(:billed_amount_cents)],
    total_paid: to_dollars[claims.sum(:paid_amount_cents)],
    total_state_share: to_dollars[claims.sum(:state_share_cents)],
    total_county_share: to_dollars[claims.sum(:county_share_cents)],
    by_provider: claims.group(:provider_identifier)
                       .sum(:paid_amount_cents)
                       .transform_values(&to_dollars)
  }
end

When("I export the report as CSV") do
  @csv_lines = []
  @csv_lines << "Provider,Paid Amount,State Share,County Share"
  claims = Corvid::ClaimSubmission.paid
  claims.group(:provider_identifier).each do |provider, _|
    provider_claims = claims.where(provider_identifier: provider)
    paid = provider_claims.sum(:paid_amount_cents) / 100.0
    state = provider_claims.sum(:state_share_cents) / 100.0
    county = provider_claims.sum(:county_share_cents) / 100.0
    @csv_lines << "#{provider},#{paid},#{state},#{county}"
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
