# frozen_string_literal: true

# Article 6 reimbursement step definitions (ported from the predecessor app)

module Article6SeedHelpers
  module_function

  def quarter_key(date)
    "#{date.year}-Q#{((date.month - 1) / 3) + 1}"
  end

  # ADR 0004: integer cents; state 60% / county 40% of paid, exact sum.
  def state_county_cents_for_paid(paid_cents)
    state_cents = paid_cents * 3 / 5
    county_cents = paid_cents - state_cents
    [ state_cents, county_cents ]
  end

  def record_in_window_paid_claim!(expected, billed_cents:, paid_cents:, provider:, currency_iso: "USD")
    state_cents, county_cents = state_county_cents_for_paid(paid_cents)
    expected[:total_claims] += 1
    expected[:total_billed_cents_by_currency][currency_iso] ||= 0
    expected[:total_billed_cents_by_currency][currency_iso] += billed_cents
    expected[:total_paid_cents_by_currency][currency_iso] ||= 0
    expected[:total_paid_cents_by_currency][currency_iso] += paid_cents
    expected[:total_state_share_cents_by_currency][currency_iso] ||= 0
    expected[:total_state_share_cents_by_currency][currency_iso] += state_cents
    expected[:total_county_share_cents_by_currency][currency_iso] ||= 0
    expected[:total_county_share_cents_by_currency][currency_iso] += county_cents
    pair = [ provider, currency_iso ]
    bucket = expected[:by_provider][pair] ||= {
      billed_cents: 0, paid_cents: 0, state_cents: 0, county_cents: 0, currency_iso: currency_iso
    }
    bucket[:billed_cents] += billed_cents
    bucket[:paid_cents] += paid_cents
    bucket[:state_cents] += state_cents
    bucket[:county_cents] += county_cents
  end

  def seed_other_tenant_paid_claim!(service_date:, billed_cents:, paid_cents:, provider:)
    state_cents, county_cents = state_county_cents_for_paid(paid_cents)
    Corvid::TenantContext.with_tenant("tnt_other_art6") do
      Corvid::ClaimSubmission.create!(
        tenant_identifier: "tnt_other_art6",
        facility_identifier: "fac_other_art6",
        patient_identifier: "pt_art6_other_tenant",
        claim_identifier: "CLM_ART6_OTHER_TENANT",
        claim_type: "professional",
        status: "paid",
        billed_amount_cents: billed_cents,
        paid_amount_cents: paid_cents,
        service_date: service_date,
        paid_date: service_date,
        provider_identifier: provider,
        state_share_cents: state_cents,
        county_share_cents: county_cents,
        submitted_at: 40.days.ago
      )
    end
  end
end

Given("there are paid claim submissions in the system") do
  @article6_expected = {
    total_claims: 0,
    total_billed_cents_by_currency: {},
    total_paid_cents_by_currency: {},
    total_state_share_cents_by_currency: {},
    total_county_share_cents_by_currency: {},
    by_provider: {}
  }

  3.times do |i|
    service_date = [ Date.current - (i + 5).days, Date.current.beginning_of_quarter ].max
    billed_cents = 50_037 + (i * 10_000)
    paid_cents = 40_029 + (i * 8_000)
    state_cents, county_cents = Article6SeedHelpers.state_county_cents_for_paid(paid_cents)
    provider = "pr_art6_#{i % 2}"
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_#{i}",
      claim_identifier: "CLM_ART6_#{i}",
      claim_type: "professional",
      status: "paid",
      billed_amount_cents: billed_cents,
      paid_amount_cents: paid_cents,
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
      state_share_cents: state_cents,
      county_share_cents: county_cents,
      submitted_at: (i + 10).days.ago
    )
    Article6SeedHelpers.record_in_window_paid_claim!(
      @article6_expected, billed_cents: billed_cents, paid_cents: paid_cents, provider: provider
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
      billed_cents: 11_137, paid_cents: 10_101 },
    { suffix: "end", service_date: Date.current.end_of_quarter, status: "paid",
      billed_cents: 22_200, paid_cents: 20_200 },
    { suffix: "unpaid", service_date: Date.current.beginning_of_quarter + 1.day,
      status: "submitted", billed_cents: 55_500, paid_cents: 0 }
  ].each do |edge|
    provider = "pr_art6_edge_#{edge[:suffix]}"
    state_cents, county_cents = Article6SeedHelpers.state_county_cents_for_paid(edge[:paid_cents])
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_edge_#{edge[:suffix]}",
      claim_identifier: "CLM_ART6_EDGE_#{edge[:suffix].upcase}",
      claim_type: "professional",
      status: edge[:status],
      billed_amount_cents: edge[:billed_cents],
      paid_amount_cents: edge[:paid_cents],
      paid_date: edge[:status] == "paid" ? edge[:service_date] : nil,
      service_date: edge[:service_date],
      provider_identifier: provider,
      state_share_cents: state_cents,
      county_share_cents: county_cents,
      submitted_at: 40.days.ago
    )
    if edge[:status] == "paid"
      Article6SeedHelpers.record_in_window_paid_claim!(
        @article6_expected,
        billed_cents: edge[:billed_cents],
        paid_cents: edge[:paid_cents],
        provider: provider
      )
    end
  end

  # Status is NOT "paid" but paid_date and paid_amount are set in-quarter.
  # Excluded from @article6_expected: `.where.not(paid_date: nil)` or
  # `paid_amount_cents > 0` instead of `.paid` would include these rows and
  # break the summary/CSV totals. One row per non-paid status kills a widened
  # `scope :paid` that treats appealed (etc.) as paid.
  (Corvid::ClaimSubmission::STATUSES - [ "paid" ]).each_with_index do |status, idx|
    pseudo_paid_service = Date.current.beginning_of_quarter + (3 + idx).days
    paid_cents = 33_300 + (idx * 11)
    billed_cents = 44_400 + (idx * 13)
    state_cents, county_cents = Article6SeedHelpers.state_county_cents_for_paid(paid_cents)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_np_#{status}",
      claim_identifier: "CLM_ART6_NP_#{status.upcase}",
      claim_type: "professional",
      status: status,
      billed_amount_cents: billed_cents,
      paid_amount_cents: paid_cents,
      service_date: pseudo_paid_service,
      paid_date: pseudo_paid_service + 1.day,
      provider_identifier: "pr_art6_np_#{status}",
      state_share_cents: state_cents,
      county_share_cents: county_cents,
      submitted_at: 40.days.ago
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
      paid_date: Date.current, billed_cents: 99_900, paid_cents: 77_700 },
    { suffix: "late", service_date: Date.current.end_of_quarter + 10.days,
      paid_date: Date.current.end_of_quarter + 10.days, billed_cents: 88_800, paid_cents: 66_600 }
  ].each do |decoy|
    state_cents, county_cents = Article6SeedHelpers.state_county_cents_for_paid(decoy[:paid_cents])
    Corvid::ClaimSubmission.create!(
      tenant_identifier: @tenant,
      facility_identifier: @facility,
      patient_identifier: "pt_art6_decoy_#{decoy[:suffix]}",
      claim_identifier: "CLM_ART6_DECOY_#{decoy[:suffix].upcase}",
      claim_type: "professional",
      status: "paid",
      billed_amount_cents: decoy[:billed_cents],
      paid_amount_cents: decoy[:paid_cents],
      paid_date: decoy[:paid_date],
      service_date: decoy[:service_date],
      provider_identifier: "pr_art6_decoy_#{decoy[:suffix]}",
      state_share_cents: state_cents,
      county_share_cents: county_cents,
      submitted_at: 40.days.ago
    )
  end

  # In-quarter paid claim for another tenant: kills reports that drop tenant scoping.
  other_service = Date.current.beginning_of_quarter + 4.days
  Article6SeedHelpers.seed_other_tenant_paid_claim!(
    service_date: other_service,
    billed_cents: 43_200,
    paid_cents: 32_100,
    provider: "pr_art6_other_tenant"
  )

  # In-window paid claim in a non-USD currency (ADR 0004: never sum across currencies).
  jod_service = Date.current.beginning_of_quarter + 7.days
  jod_billed_cents = 12_345
  jod_paid_cents = 9_876
  jod_state_cents, jod_county_cents = Article6SeedHelpers.state_county_cents_for_paid(jod_paid_cents)
  Corvid::ClaimSubmission.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: "pt_art6_jod",
    claim_identifier: "CLM_ART6_JOD",
    claim_type: "professional",
    status: "paid",
    currency_iso: "JOD",
    billed_amount_cents: jod_billed_cents,
    paid_amount_cents: jod_paid_cents,
    service_date: jod_service,
    paid_date: jod_service,
    provider_identifier: "pr_art6_jod",
    state_share_cents: jod_state_cents,
    county_share_cents: jod_county_cents,
    submitted_at: 40.days.ago
  )
  Article6SeedHelpers.record_in_window_paid_claim!(
    @article6_expected,
    billed_cents: jod_billed_cents,
    paid_cents: jod_paid_cents,
    provider: "pr_art6_jod",
    currency_iso: "JOD"
  )

  # Same provider as an existing USD row, second currency — CSV must emit two rows.
  dual_billed_cents = 6_543
  dual_paid_cents = 5_432
  dual_state_cents, dual_county_cents = Article6SeedHelpers.state_county_cents_for_paid(dual_paid_cents)
  dual_service = Date.current.beginning_of_quarter + 8.days
  Corvid::ClaimSubmission.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: "pt_art6_0_jod",
    claim_identifier: "CLM_ART6_0_JOD",
    claim_type: "professional",
    status: "paid",
    currency_iso: "JOD",
    billed_amount_cents: dual_billed_cents,
    paid_amount_cents: dual_paid_cents,
    service_date: dual_service,
    paid_date: dual_service,
    provider_identifier: "pr_art6_0",
    state_share_cents: dual_state_cents,
    county_share_cents: dual_county_cents,
    submitted_at: 40.days.ago
  )
  Article6SeedHelpers.record_in_window_paid_claim!(
    @article6_expected,
    billed_cents: dual_billed_cents,
    paid_cents: dual_paid_cents,
    provider: "pr_art6_0",
    currency_iso: "JOD"
  )
end

When("I generate an Article 6 summary report for the current quarter") do
  quarter_start = Date.current.beginning_of_quarter
  quarter_end = Date.current.end_of_quarter
  claims = Corvid::ClaimSubmission.paid.in_date_range(quarter_start..quarter_end)
  @report = {
    period: "#{quarter_start} to #{quarter_end}",
    total_claims: claims.count,
    total_billed_cents_by_currency: claims.group(:currency_iso).sum(:billed_amount_cents),
    total_paid_cents_by_currency: claims.group(:currency_iso).sum(:paid_amount_cents),
    total_state_share_cents_by_currency: claims.group(:currency_iso).sum(:state_share_cents),
    total_county_share_cents_by_currency: claims.group(:currency_iso).sum(:county_share_cents),
    by_provider_paid_cents: claims.group(:provider_identifier, :currency_iso).sum(:paid_amount_cents)
  }
end
