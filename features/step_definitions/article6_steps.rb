# frozen_string_literal: true

# Article 6 reimbursement step definitions (ported from the predecessor app)

module Article6SeedHelpers
  module_function

  def quarter_key(date)
    "#{date.year}-Q#{((date.month - 1) / 3) + 1}"
  end

  def dollars_to_cents(dollars)
    (BigDecimal(dollars.to_s) * 100).to_i
  end

  # ADR 0004: integer cents; state 60% / county 40% of paid, exact sum.
  def state_county_cents_for_paid(paid_dollars)
    paid_cents = dollars_to_cents(paid_dollars)
    state_cents = (paid_cents * 60) / 100
    county_cents = paid_cents - state_cents
    [ state_cents, county_cents ]
  end

  def record_in_window_paid_claim!(expected, billed:, paid:, provider:)
    billed_cents = dollars_to_cents(billed)
    paid_cents = dollars_to_cents(paid)
    state_cents, county_cents = state_county_cents_for_paid(paid)
    expected[:total_claims] += 1
    expected[:total_billed_cents] += billed_cents
    expected[:total_paid_cents] += paid_cents
    expected[:total_state_share_cents] += state_cents
    expected[:total_county_share_cents] += county_cents
    bucket = expected[:by_provider][provider] ||= {
      billed_cents: 0, paid_cents: 0, state_cents: 0, county_cents: 0
    }
    bucket[:billed_cents] += billed_cents
    bucket[:paid_cents] += paid_cents
    bucket[:state_cents] += state_cents
    bucket[:county_cents] += county_cents
  end
end

Given("there are paid claim submissions in the system") do
  @article6_expected = {
    total_claims: 0,
    total_billed_cents: 0,
    total_paid_cents: 0,
    total_state_share_cents: 0,
    total_county_share_cents: 0,
    by_provider: {}
  }

  3.times do |i|
    service_date = [ Date.current - (i + 5).days, Date.current.beginning_of_quarter ].max
    billed = 500.00 + (i * 100)
    paid = 400.00 + (i * 80)
    state_cents, county_cents = Article6SeedHelpers.state_county_cents_for_paid(paid)
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
      state_share: state_cents / 100.0,
      county_share: county_cents / 100.0,
      submitted_at: (i + 10).days.ago
    )
    Article6SeedHelpers.record_in_window_paid_claim!(
      @article6_expected, billed: billed, paid: paid, provider: provider
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
    state_cents, county_cents = Article6SeedHelpers.state_county_cents_for_paid(edge[:paid])
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
      state_share: state_cents / 100.0,
      county_share: county_cents / 100.0,
      submitted_at: 40.days.ago
    )
    if edge[:status] == "paid"
      Article6SeedHelpers.record_in_window_paid_claim!(
        @article6_expected,
        billed: edge[:billed],
        paid: edge[:paid],
        provider: provider
      )
    end
  end

  # Status is NOT "paid" but paid_date and paid_amount are set in-quarter.
  # Excluded from @article6_expected: `.where.not(paid_date: nil)` or
  # `paid_amount_cents > 0` instead of `.paid` would include this row and
  # break the summary/CSV totals.
  pseudo_paid_service = Date.current.beginning_of_quarter + 2.days
  pseudo_paid = 333.00
  pseudo_state_cents, pseudo_county_cents = Article6SeedHelpers.state_county_cents_for_paid(pseudo_paid)
  Corvid::ClaimSubmission.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: "pt_art6_pseudo_paid",
    claim_identifier: "CLM_ART6_PSEUDO_PAID",
    claim_type: "professional",
    status: "denied",
    billed_amount: 444.00,
    paid_amount: pseudo_paid,
    service_date: pseudo_paid_service,
    paid_date: pseudo_paid_service + 1.day,
    provider_identifier: "pr_art6_pseudo_paid",
    state_share: pseudo_state_cents / 100.0,
    county_share: pseudo_county_cents / 100.0,
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
    state_cents, county_cents = Article6SeedHelpers.state_county_cents_for_paid(decoy[:paid])
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
      state_share: state_cents / 100.0,
      county_share: county_cents / 100.0,
      submitted_at: 40.days.ago
    )
  end

  # In-quarter paid claim for another tenant: kills reports that drop tenant scoping.
  other_paid = 321.00
  other_state_cents, other_county_cents = Article6SeedHelpers.state_county_cents_for_paid(other_paid)
  other_service = Date.current.beginning_of_quarter + 4.days
  Corvid::TenantContext.with_tenant("tnt_other_art6") do
    Corvid::ClaimSubmission.create!(
      tenant_identifier: "tnt_other_art6",
      facility_identifier: "fac_other_art6",
      patient_identifier: "pt_art6_other_tenant",
      claim_identifier: "CLM_ART6_OTHER_TENANT",
      claim_type: "professional",
      status: "paid",
      billed_amount: 432.00,
      paid_amount: other_paid,
      service_date: other_service,
      paid_date: other_service,
      provider_identifier: "pr_art6_other_tenant",
      state_share: other_state_cents / 100.0,
      county_share: other_county_cents / 100.0,
      submitted_at: 40.days.ago
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
    total_billed_cents: claims.sum(:billed_amount_cents),
    total_paid_cents: claims.sum(:paid_amount_cents),
    total_state_share_cents: claims.sum(:state_share_cents),
    total_county_share_cents: claims.sum(:county_share_cents),
    by_provider_paid_cents: claims.group(:provider_identifier).sum(:paid_amount_cents)
  }
end
