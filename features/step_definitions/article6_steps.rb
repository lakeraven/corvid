# frozen_string_literal: true

# Article 6 reimbursement step definitions (ported from the predecessor app)

module Article6SeedHelpers
  module_function

  def quarter_key(date)
    "#{date.year}-Q#{((date.month - 1) / 3) + 1}"
  end

  def record_in_window_paid_claim!(expected, billed:, paid:, state:, county:, provider:)
    expected[:total_claims] += 1
    expected[:total_billed] += billed
    expected[:total_paid] += paid
    expected[:total_state_share] += state
    expected[:total_county_share] += county
    bucket = expected[:by_provider][provider] ||= { billed: 0.0, paid: 0.0, state: 0.0, county: 0.0 }
    bucket[:billed] += billed
    bucket[:paid] += paid
    bucket[:state] += state
    bucket[:county] += county
  end
end

Given("there are paid claim submissions in the system") do
  @article6_expected = {
    total_claims: 0,
    total_billed: 0.0,
    total_paid: 0.0,
    total_state_share: 0.0,
    total_county_share: 0.0,
    by_provider: {}
  }

  3.times do |i|
    service_date = [ Date.current - (i + 5).days, Date.current.beginning_of_quarter ].max
    billed = 500.00 + (i * 100)
    paid = 400.00 + (i * 80)
    state = paid * 0.5
    county = paid * 0.5
    provider = "pr_art6_#{i % 2}"
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_#{i}",
      claim_identifier: "CLM_ART6_#{i}",
      claim_type: "professional",
      status: "paid",
      billed_amount: billed,
      paid_amount: paid,
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
      provider_identifier: provider,
      state_share: state,
      county_share: county,
      submitted_at: (i + 10).days.ago
    )
    Article6SeedHelpers.record_in_window_paid_claim!(
      @article6_expected, billed: billed, paid: paid, state: state, county: county, provider: provider
    )
  end

  # Two BOUNDARY claims exactly on the window edges, both in-window and both
  # counted in the expected sum. They are what kill an off-by-one on either
  # bound: without a row on quarter_start, `quarter_start.next_day..` passes;
  # without one on quarter_end, `..quarter_end - 1.day` passes. The clamped
  # claims above only sit on quarter_start during a quarter's first week, so
  # relying on them makes the kill date-dependent.
  #
  # The NON-PAID row is what keeps the `.paid` scope under test: with every
  # seeded row paid, dropping `.paid` from the report changes nothing.
  [
    { suffix: "start", service_date: Date.current.beginning_of_quarter, status: "paid",
      billed: 111.00, paid: 101.00 },
    { suffix: "end", service_date: Date.current.end_of_quarter, status: "paid",
      billed: 222.00, paid: 202.00 },
    { suffix: "unpaid", service_date: Date.current.beginning_of_quarter + 1.day,
      status: "submitted", billed: 555.00, paid: 0.00 }
  ].each do |edge|
    provider = "pr_art6_edge_#{edge[:suffix]}"
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_edge_#{edge[:suffix]}",
      claim_identifier: "CLM_ART6_EDGE_#{edge[:suffix].upcase}",
      claim_type: "professional",
      status: edge[:status],
      billed_amount: edge[:billed],
      paid_amount: edge[:paid],
      paid_date: edge[:status] == "paid" ? edge[:service_date] : nil,
      service_date: edge[:service_date],
      provider_identifier: provider,
      state_share: edge[:paid] / 2,
      county_share: edge[:paid] / 2,
      submitted_at: 40.days.ago
    )
    if edge[:status] == "paid"
      Article6SeedHelpers.record_in_window_paid_claim!(
        @article6_expected,
        billed: edge[:billed],
        paid: edge[:paid],
        state: edge[:paid] / 2,
        county: edge[:paid] / 2,
        provider: provider
      )
    end
  end

  # Status is NOT "paid" but paid_date and paid_amount are set in-quarter.
  # Excluded from @article6_expected: `.where.not(paid_date: nil)` or
  # `paid_amount_cents > 0` instead of `.paid` would include this row and
  # break the summary/CSV totals.
  pseudo_paid_service = Date.current.beginning_of_quarter + 2.days
  Corvid::ClaimSubmission.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: "pt_art6_pseudo_paid",
    claim_identifier: "CLM_ART6_PSEUDO_PAID",
    claim_type: "professional",
    status: "denied",
    billed_amount: 444.00,
    paid_amount: 333.00,
    service_date: pseudo_paid_service,
    paid_date: pseudo_paid_service + 1.day,
    provider_identifier: "pr_art6_pseudo_paid",
    state_share: 166.50,
    county_share: 166.50,
    submitted_at: 40.days.ago
  )

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
