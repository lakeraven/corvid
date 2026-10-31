# frozen_string_literal: true

require "test_helper"
require "csv"

class Corvid::ClaimOutcomeReportTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  OTHER_TENANT = "tnt_other"

  MEASURE_KEYS = %i[
    claims_sent rejected_claims rejection_rate adjudicated_claims denied_claims denial_rate
    outcome_claims first_pass_claims first_pass_rate finalized_claims paid_claims payment_rate
  ].freeze

  JANUARY = Date.new(2025, 1, 1)
  MARCH = Date.new(2025, 3, 1)
  FULL_YEAR = Date.new(2025, 1, 1)..Date.new(2025, 12, 31)

  test "initialize requires a non-blank tenant_identifier string" do
    klass = Corvid::ClaimOutcomeReport
    assert_raises(ArgumentError) { klass.new(tenant_identifier: "", date_range: FULL_YEAR) }
    assert_raises(ArgumentError) { klass.new(tenant_identifier: nil, date_range: FULL_YEAR) }
  end

  test "initialize requires date_range to be a Range of Dates" do
    klass = Corvid::ClaimOutcomeReport
    assert_raises(ArgumentError) { klass.new(tenant_identifier: TENANT, date_range: nil) }
    assert_raises(ArgumentError) { klass.new(tenant_identifier: TENANT, date_range: "2025-01-01..2025-12-31") }
    assert_raises(ArgumentError) do
      klass.new(
        tenant_identifier: TENANT,
        date_range: Time.utc(2025, 1, 1)..Time.utc(2025, 12, 31)
      )
    end
  end

  test "rows restores the tenant context that was current before the report ran" do
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 3, 10), status: "paid", submitted_at: 1.day.ago
    )

    with_tenant(OTHER_TENANT) do
      report = Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR)
      report.rows
      assert_equal OTHER_TENANT, Corvid::TenantContext.current_tenant_identifier
    end
  end

  test "rows works when no tenant context is set" do
    Corvid::TenantContext.reset!
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 3, 10), status: "paid", submitted_at: 1.day.ago
    )

    report = Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR)
    assert_equal 1, report.rows.size
    assert_nil Corvid::TenantContext.current_tenant_identifier
  end

  test "rows is read-only and does not change claim rows" do
    claim = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 3, 10), status: "paid", submitted_at: 1.day.ago
    )
    count_before = Corvid::ClaimSubmission.unscoped.count
    updated_at_before = claim.reload.updated_at

    Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows

    assert_equal count_before, Corvid::ClaimSubmission.unscoped.count
    assert_equal updated_at_before, claim.reload.updated_at
  end

  test "rows exclude claims outside the date range nil service_date other tenants and filter mismatches" do
    in_scope = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 15), status: "paid", submitted_at: 1.day.ago
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2024, 6, 15), status: "paid", submitted_at: 1.day.ago
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: nil, status: "paid", submitted_at: 1.day.ago
    )
    create_claim_submission(
      tenant: OTHER_TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 15), status: "paid", submitted_at: 1.day.ago
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_b", facility: "fac_a",
      service_date: Date.new(2025, 6, 15), status: "paid", submitted_at: 1.day.ago
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_b",
      service_date: Date.new(2025, 6, 15), status: "paid", submitted_at: 1.day.ago
    )

    report = Corvid::ClaimOutcomeReport.new(
      tenant_identifier: TENANT,
      date_range: FULL_YEAR,
      facility_identifier: "fac_a",
      payer_identifier: "payer_a"
    )
    row = sole_row(report.rows)
    assert_equal 1, row.claims_sent
    assert_equal [ in_scope.id ], row.claim_ids(:claims_sent)
  end

  test "rows group by payer facility and month with nil identifiers kept and sorted" do
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 1, 20), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_jan_fac"
    )
    create_claim_submission(
      tenant: TENANT, payer: nil, facility: nil,
      service_date: Date.new(2025, 1, 5), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_jan_nil"
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: nil,
      service_date: Date.new(2025, 1, 25), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_jan_payer"
    )
    create_claim_submission(
      tenant: TENANT, payer: nil, facility: nil,
      service_date: Date.new(2025, 2, 5), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_feb_nil"
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_b", facility: "fac_b",
      service_date: Date.new(2025, 3, 1), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_mar"
    )

    rows = Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows

    assert rows.frozen?
    rows.each { |row| assert row.frozen? }

    assert_equal [ JANUARY, JANUARY, JANUARY, Date.new(2025, 2, 1), MARCH ], rows.map(&:month)
    assert_equal [ nil, "payer_a", "payer_a", nil, "payer_b" ], rows.map(&:payer_identifier)
    assert_equal [ nil, nil, "fac_a", nil, "fac_b" ], rows.map(&:facility_identifier)
  end

  test "row measures expose counts and rates without combining rejections and denials" do
    sent = { submitted_at: 2.days.ago }
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 3, 5), status: "paid", patient: "pt_m1", **sent
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 3, 6), status: "paid", rejected_at: 3.days.ago,
      patient: "pt_m2", **sent
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 3, 7), status: "paid", denied_at: 3.days.ago,
      patient: "pt_m3", **sent
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 3, 8), status: "denied", denied_at: 1.day.ago,
      patient: "pt_m4", **sent
    )

    row = sole_row(
      Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows
    )
    measures = row.measures

    assert_equal MEASURE_KEYS, measures.keys
    MEASURE_KEYS.each do |key|
      value = measures[key]
      if key.to_s.end_with?("_rate")
        assert_kind_of Float, value
      else
        assert_kind_of Integer, value
      end
    end

    assert_equal 4, measures[:claims_sent]
    assert_equal 1, measures[:rejected_claims]
    assert_in_delta 25.0, measures[:rejection_rate]
    assert_equal 4, measures[:adjudicated_claims]
    assert_equal 2, measures[:denied_claims]
    assert_in_delta 50.0, measures[:denial_rate]
    assert_equal 4, measures[:outcome_claims]
    assert_equal 1, measures[:first_pass_claims]
    assert_in_delta 25.0, measures[:first_pass_rate]
    assert_equal 4, measures[:finalized_claims]
    assert_equal 3, measures[:paid_claims]
    assert_in_delta 75.0, measures[:payment_rate]

    refute_includes measures.keys.map(&:to_s), "rejected_or_denied"
    row.class.public_instance_methods(false).each do |method_name|
      name = method_name.to_s.downcase
      next unless name.include?("reject") && name.include?("den")

      flunk "Row public method #{method_name} combines rejection and denial naming"
    end
  end

  test "rates equal the ClaimSubmission KPI helpers on the same claims" do
    sent = { submitted_at: 2.days.ago }
    group = []
    group << create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 1), status: "paid", patient: "pt_kpi1", **sent
    )
    group << create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 2), status: "paid", rejected_at: 3.days.ago,
      patient: "pt_kpi2", **sent
    )
    group << create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 3), status: "paid", denied_at: 3.days.ago,
      patient: "pt_kpi3", **sent
    )
    group << create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 4), status: "denied", denied_at: 1.day.ago,
      patient: "pt_kpi4", **sent
    )
    group << create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 5), status: "rejected", rejected_at: 1.day.ago,
      patient: "pt_kpi5", **sent
    )
    group << create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 6), status: "appealed", denied_at: 1.day.ago,
      patient: "pt_kpi6", **sent
    )
    group << create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 7), status: "submitted", patient: "pt_kpi7", **sent
    )
    draft = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 6, 8), status: "draft", submitted_at: nil,
      patient: "pt_kpi8"
    )
    group << draft
    all_ids = group.map(&:id)

    row = sole_row(
      Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows
    )

    with_tenant(TENANT) do
      relation = Corvid::ClaimSubmission.where(id: all_ids)
      assert_in_delta relation.rejection_rate, row.rejection_rate, 0.001
      assert_in_delta relation.denial_rate, row.denial_rate, 0.001
      assert_in_delta relation.first_pass_rate, row.first_pass_rate, 0.001
      assert_in_delta relation.payment_rate, row.payment_rate, 0.001
    end

    MEASURE_KEYS.each do |measure|
      refute_includes row.claim_ids(measure), draft.id, measure.to_s
    end
  end

  test "drill-down claim ids match measure counts and rate numerators and denominators" do
    sent = { submitted_at: 2.days.ago }
    first_pass = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 4, 1), status: "paid", patient: "pt_d1", **sent
    )
    rejected_paid = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 4, 2), status: "paid", rejected_at: 3.days.ago,
      patient: "pt_d2", **sent
    )
    denied_paid = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 4, 3), status: "paid", denied_at: 3.days.ago,
      patient: "pt_d3", **sent
    )
    denied = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 4, 4), status: "denied", denied_at: 1.day.ago,
      patient: "pt_d4", **sent
    )

    row = sole_row(
      Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows
    )

    count_measures = MEASURE_KEYS.reject { |k| k.to_s.end_with?("_rate") }
    count_measures.each do |measure|
      ids = row.claim_ids(measure)
      assert ids.frozen?
      assert_equal ids.sort, ids
      ids.each { |id| assert_kind_of Integer, id }
      assert_equal row.public_send(measure), ids.size, measure.to_s
    end

    assert_equal row.claim_ids(:rejection_rate), row.claim_ids(:rejected_claims)
    assert_equal row.claim_ids(:denial_rate), row.claim_ids(:denied_claims)
    assert_equal row.claim_ids(:first_pass_rate), row.claim_ids(:first_pass_claims)
    assert_equal row.claim_ids(:payment_rate), row.claim_ids(:paid_claims)

    assert_equal row.denominator_ids(:rejection_rate), row.claim_ids(:claims_sent)
    assert_equal row.denominator_ids(:denial_rate), row.claim_ids(:adjudicated_claims)
    assert_equal row.denominator_ids(:first_pass_rate), row.claim_ids(:outcome_claims)
    assert_equal row.denominator_ids(:payment_rate), row.claim_ids(:finalized_claims)

    assert_equal [ first_pass.id, rejected_paid.id, denied_paid.id, denied.id ].sort,
      row.claim_ids(:claims_sent)
    assert_equal [ rejected_paid.id ], row.claim_ids(:rejected_claims)
    assert_equal [ denied_paid.id, denied.id ].sort, row.claim_ids(:denied_claims)

    assert_raises(ArgumentError) { row.claim_ids(:rejected_or_denied) }
  end

  test "rejected resubmitted and paid counts toward rejection not denial or first pass" do
    claim = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 5, 1), status: "paid",
      submitted_at: 2.days.ago, rejected_at: 3.days.ago,
      patient: "pt_rej_paid"
    )

    row = sole_row(
      Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows
    )

    assert_includes row.claim_ids(:rejected_claims), claim.id
    assert_includes row.claim_ids(:paid_claims), claim.id
    refute_includes row.claim_ids(:denied_claims), claim.id
    refute_includes row.claim_ids(:first_pass_claims), claim.id
  end

  test "denied appealed and paid counts toward denial not rejection or first pass" do
    claim = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 5, 2), status: "paid",
      submitted_at: 2.days.ago, denied_at: 3.days.ago,
      patient: "pt_den_paid"
    )

    row = sole_row(
      Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows
    )

    assert_includes row.claim_ids(:denied_claims), claim.id
    assert_includes row.claim_ids(:paid_claims), claim.id
    refute_includes row.claim_ids(:rejected_claims), claim.id
    refute_includes row.claim_ids(:first_pass_claims), claim.id
  end

  test "appealed claim with denied_at counts in denied and adjudicated claims" do
    claim = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 5, 3), status: "appealed",
      submitted_at: 2.days.ago, denied_at: 1.day.ago,
      patient: "pt_appealed"
    )

    row = sole_row(
      Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows
    )

    assert_includes row.claim_ids(:denied_claims), claim.id
    assert_includes row.claim_ids(:adjudicated_claims), claim.id
  end

  test "denials_by_category maps codes uncoded and unmapped with drill-down ids" do
    medical = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 7, 1), status: "denied", submitted_at: 2.days.ago,
      denied_at: 1.day.ago, denial_reason_codes: [ "CO-50" ], patient: "pt_cat1"
    )
    missing = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 7, 2), status: "denied", submitted_at: 2.days.ago,
      denied_at: 1.day.ago, denial_reason_codes: [ "CO-16" ], patient: "pt_cat2"
    )
    unmapped = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 7, 3), status: "denied", submitted_at: 2.days.ago,
      denied_at: 1.day.ago, denial_reason_codes: [ "CO-999" ], patient: "pt_cat3"
    )
    uncoded = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 7, 4), status: "denied", submitted_at: 2.days.ago,
      denied_at: 1.day.ago, denial_reason_codes: [], patient: "pt_cat4"
    )
    dual_category = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 7, 5), status: "denied", submitted_at: 2.days.ago,
      denied_at: 1.day.ago, denial_reason_codes: %w[CO-50 CO-16], patient: "pt_cat5"
    )
    duplicate_queue = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 7, 6), status: "denied", submitted_at: 2.days.ago,
      denied_at: 1.day.ago, denial_reason_codes: [ "CO-50", " co-50 " ], patient: "pt_cat6"
    )
    coding = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 7, 7), status: "denied", submitted_at: 2.days.ago,
      denied_at: 1.day.ago, denial_reason_codes: %w[CO-50 CO-97], patient: "pt_cat7"
    )

    row = sole_row(
      Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR).rows
    )
    by_category = row.denials_by_category

    assert by_category.frozen?
    assert_equal by_category.keys.sort, by_category.keys
    assert_equal %w[coding_review medical_necessity_appeal missing_information uncoded unmapped],
      by_category.keys

    assert_equal 4, by_category["medical_necessity_appeal"]
    assert_equal 1, by_category["coding_review"]
    assert_equal 2, by_category["missing_information"]
    assert_equal 1, by_category["unmapped"]
    assert_equal 1, by_category["uncoded"]

    assert_equal [ medical.id, dual_category.id, duplicate_queue.id, coding.id ].sort,
      row.claim_ids_for_denial_category("medical_necessity_appeal")
    assert_equal [ coding.id ], row.claim_ids_for_denial_category("coding_review")
    assert_equal [ missing.id, dual_category.id ].sort,
      row.claim_ids_for_denial_category("missing_information")
    assert_equal [ unmapped.id ], row.claim_ids_for_denial_category("unmapped")
    assert_equal [ uncoded.id ], row.claim_ids_for_denial_category("uncoded")
  end

  test "to_csv exports rows measures and denial category columns without patient identifiers" do
    sent = { submitted_at: 2.days.ago }
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 8, 1), status: "paid", patient: "pt_csv1", **sent
    )
    create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 8, 2), status: "denied", denied_at: 1.day.ago,
      denial_reason_codes: [ "CO-50" ], patient: "pt_csv2", **sent
    )

    report = Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR)
    csv = report.to_csv
    table = CSV.parse(csv, headers: true)

    expected_headers = [
      "payer_identifier", "facility_identifier", "month", *MEASURE_KEYS.map(&:to_s),
      "denials_medical_necessity_appeal"
    ]
    assert_equal expected_headers, table.headers

    table.headers.each do |header|
      down = header.downcase
      assert !(down.include?("reject") && down.include?("den")), header
    end

    row = report.rows.sole
    csv_row = table.sole
    assert_equal "payer_a", csv_row["payer_identifier"]
    assert_equal "fac_a", csv_row["facility_identifier"]
    assert_equal "2025-08", csv_row["month"]
    assert_equal row.measures[:rejection_rate].to_s, csv_row["rejection_rate"]
    assert_equal "1", csv_row["denials_medical_necessity_appeal"]
    refute_includes csv, "pt_csv1"
    refute_includes csv, "pt_csv2"
  end

  test "tenant isolation keeps other tenants out of rows and id lists" do
    test_claim = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 9, 10), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_iso_test"
    )
    other_claim = create_claim_submission(
      tenant: OTHER_TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 9, 10), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_iso_other"
    )

    with_tenant(TENANT) do
      report = Corvid::ClaimOutcomeReport.new(tenant_identifier: OTHER_TENANT, date_range: FULL_YEAR)
      row = sole_row(report.rows)
      assert_equal [ other_claim.id ], row.claim_ids(:claims_sent)
      refute_includes row.claim_ids(:claims_sent), test_claim.id
    end

    report = Corvid::ClaimOutcomeReport.new(tenant_identifier: TENANT, date_range: FULL_YEAR)
    row = sole_row(report.rows)
    assert_equal [ test_claim.id ], row.claim_ids(:claims_sent)
    refute_includes row.claim_ids(:claims_sent), other_claim.id
  end

  test "facility and payer filters intersect" do
    payer_a_fac_a = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_a",
      service_date: Date.new(2025, 10, 1), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_f1"
    )
    fac_b_only = create_claim_submission(
      tenant: TENANT, payer: "payer_a", facility: "fac_b",
      service_date: Date.new(2025, 10, 2), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_f2"
    )
    payer_b_only = create_claim_submission(
      tenant: TENANT, payer: "payer_b", facility: "fac_a",
      service_date: Date.new(2025, 10, 3), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_f3"
    )
    both = create_claim_submission(
      tenant: TENANT, payer: "payer_b", facility: "fac_b",
      service_date: Date.new(2025, 10, 4), status: "paid", submitted_at: 1.day.ago,
      patient: "pt_f4"
    )

    fac_rows = Corvid::ClaimOutcomeReport.new(
      tenant_identifier: TENANT, date_range: FULL_YEAR, facility_identifier: "fac_a"
    ).rows
    assert_equal 2, fac_rows.size
    refute fac_rows.any? { |r| r.facility_identifier == "fac_b" }

    payer_rows = Corvid::ClaimOutcomeReport.new(
      tenant_identifier: TENANT, date_range: FULL_YEAR, payer_identifier: "payer_b"
    ).rows
    assert_equal 2, payer_rows.size
    refute payer_rows.any? { |r| r.payer_identifier == "payer_a" }

    both_rows = Corvid::ClaimOutcomeReport.new(
      tenant_identifier: TENANT,
      date_range: FULL_YEAR,
      facility_identifier: "fac_b",
      payer_identifier: "payer_b"
    ).rows
    assert_equal 1, both_rows.size
    assert_equal [ both.id ], both_rows.sole.claim_ids(:claims_sent)

    fac_a_ids = fac_rows.flat_map { |r| r.claim_ids(:claims_sent) }
    assert_equal [ payer_a_fac_a.id, payer_b_only.id ].sort, fac_a_ids.sort
    refute_includes fac_a_ids, fac_b_only.id
    refute_includes fac_a_ids, both.id

    payer_b_ids = payer_rows.flat_map { |r| r.claim_ids(:claims_sent) }
    assert_equal [ payer_b_only.id, both.id ].sort, payer_b_ids.sort
    refute_includes payer_b_ids, fac_b_only.id
  end

  test "claim outcome report documentation lists measures unmapped and uncoded" do
    path = File.expand_path("../../../docs/claim_outcome_report.md", __dir__)
    assert_path_exists path, "docs/claim_outcome_report.md must exist"

    text = File.read(path)
    MEASURE_KEYS.each do |key|
      assert_includes text, key.to_s, "docs must define #{key}"
    end
    assert_includes text, "unmapped"
    assert_includes text, "uncoded"
  end

  private

  def create_claim_submission(tenant:, service_date:, patient: "pt_001", **attrs)
    with_tenant(tenant) do
      Corvid::ClaimSubmission.create!(
        tenant_identifier: tenant,
        facility_identifier: attrs.delete(:facility) { "fac_a" },
        payer_identifier: attrs.delete(:payer) { "payer_a" },
        patient_identifier: patient,
        claim_type: "professional",
        service_date: service_date,
        status: attrs.delete(:status) { "submitted" },
        **attrs
      )
    end
  end

  def sole_row(rows)
    assert_equal 1, rows.size, "expected a single report row, got #{rows.size}"
    rows.sole
  end
end
