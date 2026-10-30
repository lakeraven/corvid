# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "corvid/rcm"

class Corvid::Rcm::PostingPlanTest < Minitest::Test
  FIXTURES = Corvid::Rcm::FixtureClearinghouseClient::FIXTURE_DIR

  ALL_835_SCENARIOS = (
    Corvid::Rcm::FixtureClearinghouseClient::SCENARIOS +
    %w[
      reversal_claim_status_22
      payer_initiated_reduction_pi
    ]
  ).freeze

  POSTING_ENTRY_MEMBERS = %i[
    claim_identifier
    payer_control_number
    kind
    amount
    group_code
    reason_code
    service_line
  ].freeze

  def setup
    @client = Corvid::Rcm::FixtureClearinghouseClient.new
  end

  def plan_from(remittance)
    Corvid::Rcm::PostingPlan.from(remittance)
  end

  def entries_for(plan, claim_identifier)
    plan.entries.select { |entry| entry.claim_identifier == claim_identifier }
  end

  def unbalanced_for(plan, claim_identifier)
    plan.unbalanced.find { |row| row.claim_identifier == claim_identifier }
  end

  # -- shape -----------------------------------------------------------------

  def test_posting_plan_from_returns_a_frozen_plan_with_entries_and_unbalanced
    remittance = @client.remittance("clean_full_pay")
    plan = plan_from(remittance)

    assert_kind_of Corvid::Rcm::PostingPlan, plan
    assert plan.frozen?
    assert plan.entries.frozen?
    assert plan.unbalanced.frozen?
    assert_equal plan.entries, plan.to_a
  end

  def test_posting_entry_is_frozen_data_with_expected_members
    plan = plan_from(@client.remittance("clean_full_pay"))
    entry = plan.entries.first

    assert_kind_of Corvid::Rcm::PostingEntry, entry
    assert entry.frozen?
    assert_equal POSTING_ENTRY_MEMBERS, entry.members
    assert_instance_of BigDecimal, entry.amount
  end

  def test_posting_entry_and_plan_inspect_never_carry_patient_identifier
    remittance = @client.remittance("clean_full_pay")
    claim = remittance.claim("CLM-1001")
    refute_nil claim.patient_identifier

    plan = plan_from(remittance)
    plan.entries.each do |entry|
      refute_includes entry.members, :patient_identifier
    end
    refute_includes plan.inspect, claim.patient_identifier
  end

  def test_unbalanced_claim_row_exposes_identifier_control_number_and_unexplained_amount
    remittance = unbalanced_remittance_from_fixture("partial_pay_patient_responsibility")
    plan = plan_from(remittance)
    row = plan.unbalanced.find { |u| u.claim_identifier == "CLM-1002" }

    assert_kind_of Corvid::Rcm::UnbalancedClaim, row
    assert_equal "PAYER-CTL-1002", row.payer_control_number
    assert_equal BigDecimal("-1.00"), row.unexplained_amount
    assert_instance_of BigDecimal, row.unexplained_amount
  end

  # -- partial pay fixture (specific expectations) ---------------------------

  def test_partial_pay_patient_responsibility_posts_payment_and_cas_adjustments
    claim = @client.remittance("partial_pay_patient_responsibility").claim("CLM-1002")
    plan = plan_from(@client.remittance("partial_pay_patient_responsibility"))
    entries = entries_for(plan, "CLM-1002")

    assert_equal BigDecimal("200.00"), claim.billed_amount
    assert_equal BigDecimal("90.00"), claim.paid_amount
    assert_empty plan.unbalanced

    payments = entries.select { |e| e.kind == :payer_payment }
    assert_equal 1, payments.length
    assert_equal BigDecimal("90.00"), payments.first.amount
    assert_nil payments.first.group_code
    assert_nil payments.first.reason_code
    assert_kind_of Corvid::Rcm::PostingServiceLine, payments.first.service_line
    assert_equal "90837", payments.first.service_line.procedure_code
    assert_equal Date.new(2026, 8, 18), payments.first.service_line.serviced_date

    contractual = entries.find { |e| e.kind == :contractual_adjustment }
    assert_equal BigDecimal("50.00"), contractual.amount
    assert_equal "CO", contractual.group_code
    assert_equal "45", contractual.reason_code

    patient_rows = entries.select { |e| e.kind == :patient_responsibility }.sort_by(&:reason_code)
    assert_equal 3, patient_rows.length
    assert_equal [ BigDecimal("30.00"), BigDecimal("20.00"), BigDecimal("10.00") ],
                 patient_rows.map(&:amount)
    assert_equal %w[1 2 3], patient_rows.map(&:reason_code)
    assert_equal [ "PR", "PR", "PR" ], patient_rows.map(&:group_code)
  end

  # -- denial with unmapped CARC still posts ---------------------------------

  def test_denial_unmapped_reason_code_still_posts_its_contractual_adjustment
    plan = plan_from(@client.remittance("denial_unmapped_reason_code"))
    entries = entries_for(plan, "CLM-1009")

    refute_empty entries
    adjustment = entries.find { |e| e.group_code == "CO" && e.reason_code == "234" }
    refute_nil adjustment, "unmapped CARC must still produce a posting entry"
    assert_equal :contractual_adjustment, adjustment.kind
    assert_equal BigDecimal("185.00"), adjustment.amount
    refute entries.any? { |e| e.kind == :payer_payment }
  end

  # -- payer-initiated reduction fixture -------------------------------------

  def test_payer_initiated_reduction_pi_fixture_posts_pi_adjustments
    plan = plan_from(@client.remittance("payer_initiated_reduction_pi"))
    pi_entries = plan.entries.select do |entry|
      entry.kind == :payer_initiated_reduction && entry.group_code == "PI"
    end

    refute_empty pi_entries
  end

  # -- payer payment rules ---------------------------------------------------

  def test_claim_without_service_lines_gets_one_claim_level_payer_payment
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-NOSVC",
      payer_control_number: "PAYER-NOSVC",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("125.00"),
      paid_amount: BigDecimal("125.00"),
      services: [],
      adjustments: []
    )
    remittance = Corvid::Rcm::Remittance.new(
      remittance_identifier: "REM-NOSVC",
      payment_amount: BigDecimal("125.00"),
      claims: [ claim ]
    )
    plan = plan_from(remittance)
    entries = entries_for(plan, "CLM-NOSVC")

    assert_equal 1, entries.length
    assert_equal :payer_payment, entries.first.kind
    assert_equal BigDecimal("125.00"), entries.first.amount
    assert_nil entries.first.service_line
  end

  def test_zero_paid_amount_produces_no_payer_payment_entry
    plan = plan_from(@client.remittance("denial_unmapped_reason_code"))
    refute plan.entries.any? { |entry| entry.kind == :payer_payment }
  end

  # -- CAS group mapping -----------------------------------------------------

  def test_cas_group_codes_map_to_posting_kinds
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-MAP",
      payer_control_number: "PAYER-MAP",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("80.00"),
      paid_amount: BigDecimal("10.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("10.00")),
        Corvid::Rcm::Adjustment.new(group_code: "PR", reason_code: "1", amount: BigDecimal("10.00")),
        Corvid::Rcm::Adjustment.new(
          group_code: Corvid::Rcm::ADJUSTMENT_GROUP_OTHER, reason_code: "23", amount: BigDecimal("10.00")
        ),
        Corvid::Rcm::Adjustment.new(group_code: "PI", reason_code: "59", amount: BigDecimal("10.00")),
        Corvid::Rcm::Adjustment.new(group_code: "OI", reason_code: "23", amount: BigDecimal("10.00")),
        Corvid::Rcm::Adjustment.new(group_code: "CR", reason_code: "1", amount: BigDecimal("10.00")),
        Corvid::Rcm::Adjustment.new(group_code: "ZZ", reason_code: "999", amount: BigDecimal("10.00"))
      ]
    )
    remittance = Corvid::Rcm::Remittance.new(
      remittance_identifier: "REM-MAP",
      payment_amount: BigDecimal("10.00"),
      claims: [ claim ]
    )
    plan = plan_from(remittance)
    entries = entries_for(plan, "CLM-MAP")

    assert_empty plan.unbalanced
    assert_equal 8, entries.length

    by_kind = entries.group_by(&:kind)
    assert_equal 1, by_kind.fetch(:payer_payment).length
    assert_equal 1, by_kind.fetch(:contractual_adjustment).length
    assert_equal 1, by_kind.fetch(:patient_responsibility).length
    assert_equal 1, by_kind.fetch(:other_payer).length
    assert_equal Corvid::Rcm::ADJUSTMENT_GROUP_OTHER, by_kind.fetch(:other_payer).first.group_code
    assert_equal 1, by_kind.fetch(:payer_initiated_reduction).length
    unclassified = by_kind.fetch(:unclassified)
    assert_equal 3, unclassified.length
    assert_equal %w[CR OI ZZ].sort, unclassified.map(&:group_code).sort
    unclassified.each { |entry| assert_equal BigDecimal("10.00"), entry.amount }
  end

  def test_service_lines_must_each_balance_and_sum_to_claim_billed_or_unbalanced
    serviced = Date.new(2026, 8, 18)
    balanced_line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("80.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("20.00"))
      ]
    )
    unbalanced_line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90785",
      billed_amount: BigDecimal("50.00"),
      paid_amount: BigDecimal("0.00"),
      serviced_date: serviced,
      adjustments: []
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-LINEBAL",
      payer_control_number: "PAYER-LINEBAL",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("80.00"),
      services: [ balanced_line, unbalanced_line ],
      adjustments: []
    )
    remittance = synthetic_remittance("REM-LINEBAL", BigDecimal("80.00"), [ claim ])
    plan = plan_from(remittance)

    assert_equal 1, plan.unbalanced.length
    row = unbalanced_for(plan, "CLM-LINEBAL")
    refute_nil row
    assert_equal "PAYER-LINEBAL", row.payer_control_number
    assert_empty entries_for(plan, "CLM-LINEBAL")
  end

  def test_claim_level_cas_with_balanced_lines_posts_nil_service_line_and_reconciles
    serviced = Date.new(2026, 8, 18)
    line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("80.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("20.00"))
      ]
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-CLCAS",
      payer_control_number: "PAYER-CLCAS",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("130.00"),
      paid_amount: BigDecimal("80.00"),
      services: [ line ],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "PR", reason_code: "1", amount: BigDecimal("30.00"))
      ]
    )
    remittance = synthetic_remittance("REM-CLCAS", BigDecimal("80.00"), [ claim ])
    plan = plan_from(remittance)
    entries = entries_for(plan, "CLM-CLCAS")

    assert_empty plan.unbalanced
    assert_equal BigDecimal("130.00"), entries.sum(BigDecimal(0), &:amount)

    payment = entries.find { |e| e.kind == :payer_payment }
    refute_nil payment
    assert_equal BigDecimal("80.00"), payment.amount
    assert_kind_of Corvid::Rcm::PostingServiceLine, payment.service_line
    assert_equal "90837", payment.service_line.procedure_code
    assert_equal serviced, payment.service_line.serviced_date

    contractual = entries.find { |e| e.kind == :contractual_adjustment }
    refute_nil contractual
    assert_equal BigDecimal("20.00"), contractual.amount
    assert_kind_of Corvid::Rcm::PostingServiceLine, contractual.service_line

    claim_pr = entries.find { |e| e.kind == :patient_responsibility && e.group_code == "PR" }
    refute_nil claim_pr
    assert_equal BigDecimal("30.00"), claim_pr.amount
    assert_nil claim_pr.service_line
  end

  def test_zero_amount_adjustments_are_kept_not_dropped
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-ZEROADJ",
      payer_control_number: "PAYER-ZERO",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("100.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal(0))
      ]
    )
    remittance = Corvid::Rcm::Remittance.new(
      remittance_identifier: "REM-ZEROADJ",
      payment_amount: BigDecimal("100.00"),
      claims: [ claim ]
    )
    plan = plan_from(remittance)
    zero_adj = entries_for(plan, "CLM-ZEROADJ").find { |e| e.kind == :contractual_adjustment }

    refute_nil zero_adj
    assert_equal BigDecimal(0), zero_adj.amount
  end

  # -- no silent loss of money -----------------------------------------------

  def test_balanced_non_reversal_claim_entry_amounts_reconcile_to_billed
    remittance = @client.remittance("partial_pay_patient_responsibility")
    claim = remittance.claim("CLM-1002")
    plan = plan_from(remittance)
    entries = entries_for(plan, "CLM-1002")

    payment_total = entries.select { |e| e.kind == :payer_payment }.sum(BigDecimal(0), &:amount)
    adjustment_total = entries.reject { |e| e.kind == :payer_payment }.sum(BigDecimal(0), &:amount)

    assert_equal claim.paid_amount, payment_total
    assert_equal claim.total_adjustment_amount, adjustment_total
    assert_equal claim.billed_amount, entries.sum(BigDecimal(0), &:amount)
  end

  # -- balance and service-line consistency ----------------------------------

  def test_unbalanced_claim_is_listed_and_contributes_no_entries
    remittance = unbalanced_remittance_from_fixture("partial_pay_patient_responsibility")
    plan = plan_from(remittance)

    assert_equal 1, plan.unbalanced.length
    assert_empty entries_for(plan, "CLM-1002")
  end

  def test_other_balanced_claims_in_the_same_remittance_still_post
    source = File.read(File.join(FIXTURES, "clean_full_pay.835"))
                 .sub("BPR*I*200.00*", "BPR*I*350.00*")
                 .sub("CLP*CLM-1001*1*200.00*200.00", "CLP*CLM-1001*1*201.00*200.00")
                 .sub("SE*12*0001~", "CLP*CLM-1099*1*150.00*150.00*0*12*PAYER-CTL-1099*11~SE*13*0001~")
    remittance = read_remittance_source(source)
    plan = plan_from(remittance)

    refute_nil unbalanced_for(plan, "CLM-1001")
    refute_empty entries_for(plan, "CLM-1099")
  end

  def test_service_line_paid_amounts_must_sum_to_claim_paid_or_claim_is_unbalanced
    base = @client.remittance("clean_full_pay").claim("CLM-1001")
    service = base.services.first
    mismatched = Corvid::Rcm::RemittanceService.new(
      procedure_code: service.procedure_code,
      modifiers: service.modifiers,
      billed_amount: service.billed_amount,
      paid_amount: BigDecimal("150.00"),
      units: service.units,
      serviced_date: service.serviced_date,
      adjustments: service.adjustments,
      remark_codes: service.remark_codes
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: base.claim_identifier,
      payer_control_number: base.payer_control_number,
      status_code: base.status_code,
      billed_amount: base.billed_amount,
      paid_amount: base.paid_amount,
      patient_responsibility_amount: base.patient_responsibility_amount,
      patient_identifier: base.patient_identifier,
      serviced_date: base.serviced_date,
      services: [ mismatched ],
      adjustments: base.adjustments,
      remark_codes: base.remark_codes
    )
    remittance = Corvid::Rcm::Remittance.new(
      remittance_identifier: "REM-MISMATCH",
      payment_amount: base.paid_amount,
      claims: [ claim ]
    )
    plan = plan_from(remittance)

    refute_nil unbalanced_for(plan, "CLM-1001")
    assert_empty entries_for(plan, "CLM-1001")
  end

  # -- reversal (CLP02 22) ---------------------------------------------------

  def test_reversal_claim_status_22_fixture_posts_only_reversal_entries_with_reported_amounts
    remittance = @client.remittance("reversal_claim_status_22")
    claim = remittance.claims.first
    plan = plan_from(remittance)

    assert claim.reversal?
    assert claim.balanced?
    assert_empty plan.unbalanced

    entries = entries_for(plan, claim.claim_identifier)
    refute_empty entries
    assert entries.all? { |entry| entry.kind == :reversal }
    assert entries.any? { |entry| entry.amount.negative? }
    co_entry = entries.find { |entry| entry.group_code == "CO" && entry.reason_code == "45" }
    refute_nil co_entry
    assert co_entry.amount.negative?
  end

  def test_reversal_with_positive_paid_amount_is_unbalanced_and_not_posted
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-BADREV",
      payer_control_number: "PAYER-BADREV",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("-200.00"),
      paid_amount: BigDecimal("50.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("-250.00"))
      ]
    )
    remittance = Corvid::Rcm::Remittance.new(
      remittance_identifier: "REM-BADREV",
      payment_amount: BigDecimal("50.00"),
      claims: [ claim ]
    )
    plan = plan_from(remittance)

    refute_nil unbalanced_for(plan, "CLM-BADREV")
    assert_empty entries_for(plan, "CLM-BADREV")
  end

  def test_reversal_with_non_positive_claim_totals_but_positive_service_line_amounts_is_unbalanced
    serviced = Date.new(2026, 8, 18)
    positive_line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("50.00"),
      paid_amount: BigDecimal("50.00"),
      serviced_date: serviced,
      adjustments: []
    )
    negative_line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90785",
      billed_amount: BigDecimal("-150.00"),
      paid_amount: BigDecimal("-150.00"),
      serviced_date: serviced,
      adjustments: []
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-REVPOSLINE",
      payer_control_number: "PAYER-REVPOSLINE",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("-100.00"),
      paid_amount: BigDecimal("-100.00"),
      services: [ positive_line, negative_line ],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-REVPOSLINE", BigDecimal("-100.00"), [ claim ]))

    assert_equal 1, plan.unbalanced.length
    refute_nil unbalanced_for(plan, "CLM-REVPOSLINE")
    assert_empty entries_for(plan, "CLM-REVPOSLINE")
  end

  def test_non_reversal_with_negative_claim_paid_amount_is_unbalanced_and_not_posted
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-NEGPAID",
      payer_control_number: "PAYER-NEGPAID",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("-50.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("150.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-NEGPAID", BigDecimal("-50.00"), [ claim ]))

    assert_equal 1, plan.unbalanced.length
    refute_nil unbalanced_for(plan, "CLM-NEGPAID")
    assert_empty entries_for(plan, "CLM-NEGPAID")
  end

  def test_non_reversal_with_negative_service_line_paid_while_claim_totals_balance_is_unbalanced
    serviced = Date.new(2026, 8, 18)
    negative_paid_line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("-20.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("120.00"))
      ]
    )
    offset_line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90785",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("120.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("-20.00"))
      ]
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-NEGLINEPAID",
      payer_control_number: "PAYER-NEGLINEPAID",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("200.00"),
      paid_amount: BigDecimal("100.00"),
      services: [ negative_paid_line, offset_line ],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-NEGLINEPAID", BigDecimal("100.00"), [ claim ]))

    assert_equal 1, plan.unbalanced.length
    refute_nil unbalanced_for(plan, "CLM-NEGLINEPAID")
    assert_empty entries_for(plan, "CLM-NEGLINEPAID")
  end

  def test_balanced_claim_totals_with_each_service_line_off_in_opposite_directions_is_unbalanced
    serviced = Date.new(2026, 8, 18)
    short_line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("80.00"),
      serviced_date: serviced,
      adjustments: []
    )
    long_line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90785",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("80.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("40.00"))
      ]
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-OPPLINEOFF",
      payer_control_number: "PAYER-OPPLINEOFF",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("200.00"),
      paid_amount: BigDecimal("160.00"),
      services: [ short_line, long_line ],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-OPPLINEOFF", BigDecimal("160.00"), [ claim ]))

    assert_equal 1, plan.unbalanced.length
    refute_nil unbalanced_for(plan, "CLM-OPPLINEOFF")
    assert_empty entries_for(plan, "CLM-OPPLINEOFF")
  end

  def test_reversal_claim_status_22_fixture_reversal_entries_carry_matching_service_line_context
    remittance = @client.remittance("reversal_claim_status_22")
    claim = remittance.claims.first
    plan = plan_from(remittance)
    entries = entries_for(plan, claim.claim_identifier)
    expected_line = Corvid::Rcm::PostingServiceLine.new(
      procedure_code: "90837",
      serviced_date: Date.new(2026, 8, 30)
    )

    payment = entries.find { |e| e.kind == :reversal && e.group_code.nil? }
    refute_nil payment
    assert_equal BigDecimal("-150.00"), payment.amount
    assert_equal expected_line, payment.service_line

    co_45 = entries.find { |e| e.kind == :reversal && e.group_code == "CO" && e.reason_code == "45" }
    refute_nil co_45
    assert_equal BigDecimal("-50.00"), co_45.amount
    assert_equal expected_line, co_45.service_line
  end

  def test_reversal_with_positive_billed_amount_is_unbalanced_and_not_posted
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-REVPOSBILLED",
      payer_control_number: "PAYER-REVPOSBILLED",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("200.00"),
      paid_amount: BigDecimal("0.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "50", amount: BigDecimal("200.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-REVPOSBILLED", BigDecimal("0.00"), [ claim ]))

    assert_equal 1, plan.unbalanced.length
    assert_empty entries_for(plan, "CLM-REVPOSBILLED")
  end

  def test_unbalanced_reversal_at_claim_level_posts_nothing
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-REVUNBAL",
      payer_control_number: "PAYER-REVUNBAL",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("-200.00"),
      paid_amount: BigDecimal("-150.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("-60.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-REVUNBAL", BigDecimal("-150.00"), [ claim ]))

    refute_nil unbalanced_for(plan, "CLM-REVUNBAL")
    assert_empty entries_for(plan, "CLM-REVUNBAL")
  end

  def test_reversal_whose_line_paid_amounts_do_not_sum_to_claim_paid_is_unbalanced
    serviced = Date.new(2026, 8, 18)
    line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("-100.00"),
      paid_amount: BigDecimal("-90.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("-10.00"))
      ]
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-REVLINEMISMATCH",
      payer_control_number: "PAYER-REVLINEMISMATCH",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("-100.00"),
      paid_amount: BigDecimal("-80.00"),
      services: [ line ],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-REVLINEMISMATCH", BigDecimal("-80.00"), [ claim ]))

    assert_equal 1, plan.unbalanced.length
    assert_empty entries_for(plan, "CLM-REVLINEMISMATCH")
  end

  def test_balanced_reversal_keeps_positive_cas_amount_as_reversal_kind
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-REVPOSCAS",
      payer_control_number: "PAYER-REVPOSCAS",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("-100.00"),
      paid_amount: BigDecimal("-150.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("50.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-REVPOSCAS", BigDecimal("-150.00"), [ claim ]))
    entries = entries_for(plan, "CLM-REVPOSCAS")

    assert_empty plan.unbalanced
    assert entries.all? { |entry| entry.kind == :reversal }
    positive_cas = entries.find { |e| e.group_code == "CO" && e.reason_code == "45" }
    refute_nil positive_cas
    assert_equal BigDecimal("50.00"), positive_cas.amount
  end

  def test_reversal_without_service_lines_posts_claim_payment_as_reversal_not_payer_payment
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-REVNOSVC",
      payer_control_number: "PAYER-REVNOSVC",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("-125.00"),
      paid_amount: BigDecimal("-125.00"),
      services: [],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-REVNOSVC", BigDecimal("-125.00"), [ claim ]))
    entries = entries_for(plan, "CLM-REVNOSVC")

    assert_empty plan.unbalanced
    assert_equal 1, entries.length
    assert_equal :reversal, entries.first.kind
    refute entries.any? { |e| e.kind == :payer_payment }
    assert_equal BigDecimal("-125.00"), entries.first.amount
    assert_nil entries.first.service_line
  end

  def test_group_kinds_constant_lives_on_posting_plan_not_rcm_module
    assert Corvid::Rcm::PostingPlan.const_defined?(:GROUP_KINDS, false)
    refute Corvid::Rcm.const_defined?(:GROUP_KINDS, false)
  end

  def test_every_fixture_plan_entry_amount_is_bigdecimal
    ALL_835_SCENARIOS.each do |scenario|
      plan = plan_from(@client.remittance(scenario))
      plan.entries.each do |entry|
        assert_instance_of BigDecimal, entry.amount,
                           "expected BigDecimal for #{scenario} #{entry.claim_identifier} #{entry.kind}"
      end
    end
  end

  def test_fixture_plans_carry_payer_control_number_and_line_context_on_adjustments
    ALL_835_SCENARIOS.each do |scenario|
      remittance = @client.remittance(scenario)
      plan = plan_from(remittance)

      remittance.claims.each do |claim|
        entries = entries_for(plan, claim.claim_identifier)
        next if entries.empty?

        entries.each do |entry|
          assert_equal claim.payer_control_number, entry.payer_control_number
        end

        line_adjustments = entries.reject { |e| e.kind == :payer_payment || e.kind == :reversal }
                                  .select { |e| !e.group_code.nil? && !e.service_line.nil? }
        line_adjustments.each do |entry|
          assert_kind_of Corvid::Rcm::PostingServiceLine, entry.service_line
          refute_empty entry.service_line.procedure_code
          refute_nil entry.service_line.serviced_date
        end

        claim_level_adjustments = entries.select { |e| !e.group_code.nil? && e.service_line.nil? }
        claim_level_adjustments.each do |entry|
          assert_nil entry.service_line
        end
      end
    end
  end

  def test_zero_paid_claim_without_service_lines_still_posts_adjustments_not_payment
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-ZEROPAYADJ",
      payer_control_number: "PAYER-ZEROPAYADJ",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("50.00"),
      paid_amount: BigDecimal("0.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("50.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-ZEROPAYADJ", BigDecimal("0.00"), [ claim ]))
    entries = entries_for(plan, "CLM-ZEROPAYADJ")

    assert_empty plan.unbalanced
    refute entries.any? { |e| e.kind == :payer_payment }
    assert_equal 1, entries.length
    assert_equal :contractual_adjustment, entries.first.kind
    assert_equal BigDecimal("50.00"), entries.first.amount
  end

  # -- every 835 fixture -----------------------------------------------------

  def test_every_835_fixture_yields_a_plan_without_raising
    ALL_835_SCENARIOS.each do |scenario|
      remittance = @client.remittance(scenario)
      plan = plan_from(remittance)

      remittance.claims.each do |claim|
        if claim.reversal?
          assert_reversal_claim_posting(plan, claim)
        elsif !claim.balanced? || service_line_paid_mismatch?(claim)
          assert_unbalanced_claim_posting(plan, claim)
        else
          assert_balanced_claim_posting(plan, claim)
        end
      end
    end
  end

  # -- issue #749 review round 3 (J1–J6) -------------------------------------

  def test_issue_749_j1_non_reversal_negative_billed_no_lines_unbalanced_and_not_posted
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-J1",
      payer_control_number: "PAYER-J1",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("-50.00"),
      paid_amount: BigDecimal("0.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("-50.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-J1", BigDecimal("0.00"), [ claim ]))

    assert_unbalanced_no_entries(plan, "CLM-J1", "PAYER-J1")
  end

  def test_issue_749_j2_claim_level_negative_billed_with_zero_line_unbalanced_and_not_posted
    serviced = Date.new(2026, 8, 18)
    line = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("0.00"),
      paid_amount: BigDecimal("0.00"),
      serviced_date: serviced,
      adjustments: []
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-J2-CLNEG",
      payer_control_number: "PAYER-J2-CLNEG",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("-50.00"),
      paid_amount: BigDecimal("0.00"),
      services: [ line ],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("-50.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-J2-CLNEG", BigDecimal("0.00"), [ claim ]))

    assert_unbalanced_no_entries(plan, "CLM-J2-CLNEG", "PAYER-J2-CLNEG")
  end

  def test_issue_749_j2_balanced_totals_with_negative_line_billed_unbalanced_and_not_posted
    serviced = Date.new(2026, 8, 18)
    line_a = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("150.00"),
      paid_amount: BigDecimal("100.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("50.00"))
      ]
    )
    line_b = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90785",
      billed_amount: BigDecimal("-50.00"),
      paid_amount: BigDecimal("0.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("-50.00"))
      ]
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-J2-NEGLINE",
      payer_control_number: "PAYER-J2-NEGLINE",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("100.00"),
      services: [ line_a, line_b ],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-J2-NEGLINE", BigDecimal("100.00"), [ claim ]))

    assert_unbalanced_no_entries(plan, "CLM-J2-NEGLINE", "PAYER-J2-NEGLINE")
  end

  def test_issue_749_j3_each_line_must_balance_even_when_claim_totals_reconcile
    serviced = Date.new(2026, 8, 18)
    line_a = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("80.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("20.00"))
      ]
    )
    line_b = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90785",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("90.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("20.00"))
      ]
    )
    line_c = Corvid::Rcm::RemittanceService.new(
      procedure_code: "99213",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("70.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("20.00"))
      ]
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-J3",
      payer_control_number: "PAYER-J3",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("300.00"),
      paid_amount: BigDecimal("240.00"),
      services: [ line_a, line_b, line_c ],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-J3", BigDecimal("240.00"), [ claim ]))

    assert_unbalanced_no_entries(plan, "CLM-J3", "PAYER-J3")
  end

  def test_issue_749_j4_denied_claim_with_positive_paid_and_no_cas_unbalanced_and_not_posted
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-J4-BAD",
      payer_control_number: "PAYER-J4-BAD",
      status_code: Corvid::Rcm::CLAIM_STATUS_DENIED,
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("100.00"),
      services: [],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-J4-BAD", BigDecimal("100.00"), [ claim ]))

    assert_unbalanced_no_entries(plan, "CLM-J4-BAD", "PAYER-J4-BAD")
  end

  def test_issue_749_j4_denied_claim_zero_paid_with_co50_posts_contractual_adjustment
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-J4-OK",
      payer_control_number: "PAYER-J4-OK",
      status_code: Corvid::Rcm::CLAIM_STATUS_DENIED,
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("0.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "50", amount: BigDecimal("100.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-J4-OK", BigDecimal("0.00"), [ claim ]))
    entries = entries_for(plan, "CLM-J4-OK")

    assert_empty plan.unbalanced
    refute entries.any? { |e| e.kind == :payer_payment }
    assert_equal 1, entries.length
    assert_equal :contractual_adjustment, entries.first.kind
    assert_equal BigDecimal("100.00"), entries.first.amount
    assert_equal "CO", entries.first.group_code
    assert_equal "50", entries.first.reason_code
  end

  def test_issue_749_j5_split_payer_payment_and_contractual_per_service_line
    serviced = Date.new(2026, 8, 18)
    line_90837 = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90837",
      billed_amount: BigDecimal("100.00"),
      paid_amount: BigDecimal("60.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("40.00"))
      ]
    )
    line_90785 = Corvid::Rcm::RemittanceService.new(
      procedure_code: "90785",
      billed_amount: BigDecimal("50.00"),
      paid_amount: BigDecimal("30.00"),
      serviced_date: serviced,
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("20.00"))
      ]
    )
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-J5",
      payer_control_number: "PAYER-J5",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("150.00"),
      paid_amount: BigDecimal("90.00"),
      services: [ line_90837, line_90785 ],
      adjustments: []
    )
    plan = plan_from(synthetic_remittance("REM-J5", BigDecimal("90.00"), [ claim ]))
    entries = entries_for(plan, "CLM-J5")

    assert_empty plan.unbalanced
    payment_90837 = entries.find do |e|
      e.kind == :payer_payment && e.service_line&.procedure_code == "90837"
    end
    refute_nil payment_90837
    assert_equal BigDecimal("60.00"), payment_90837.amount

    payment_90785 = entries.find do |e|
      e.kind == :payer_payment && e.service_line&.procedure_code == "90785"
    end
    refute_nil payment_90785
    assert_equal BigDecimal("30.00"), payment_90785.amount

    contractual_90837 = entries.find do |e|
      e.kind == :contractual_adjustment && e.service_line&.procedure_code == "90837"
    end
    refute_nil contractual_90837
    assert_equal BigDecimal("40.00"), contractual_90837.amount
    assert_equal "CO", contractual_90837.group_code
    assert_equal "45", contractual_90837.reason_code

    contractual_90785 = entries.find do |e|
      e.kind == :contractual_adjustment && e.service_line&.procedure_code == "90785"
    end
    refute_nil contractual_90785
    assert_equal BigDecimal("20.00"), contractual_90785.amount
    assert_equal "CO", contractual_90785.group_code
    assert_equal "45", contractual_90785.reason_code
  end

  def test_issue_749_j6_reversal_keeps_zero_amount_co45_adjustment_alongside_payment
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-J6",
      payer_control_number: "PAYER-J6",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("-100.00"),
      paid_amount: BigDecimal("-100.00"),
      services: [],
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("0.00"))
      ]
    )
    plan = plan_from(synthetic_remittance("REM-J6", BigDecimal("-100.00"), [ claim ]))
    entries = entries_for(plan, "CLM-J6")

    assert_empty plan.unbalanced
    payment = entries.find { |e| e.kind == :reversal && e.group_code.nil? }
    refute_nil payment
    assert_equal BigDecimal("-100.00"), payment.amount

    zero_co = entries.find { |e| e.kind == :reversal && e.group_code == "CO" && e.reason_code == "45" }
    refute_nil zero_co
    assert_equal BigDecimal("0.00"), zero_co.amount
  end

  private

  def assert_unbalanced_no_entries(plan, claim_identifier, payer_control_number)
    assert_equal 1, plan.unbalanced.length
    row = unbalanced_for(plan, claim_identifier)
    refute_nil row
    assert_equal payer_control_number, row.payer_control_number
    assert_empty entries_for(plan, claim_identifier)
  end

  def synthetic_remittance(remittance_identifier, payment_amount, claims)
    Corvid::Rcm::Remittance.new(
      remittance_identifier: remittance_identifier,
      payment_amount: payment_amount,
      claims: claims
    )
  end

  def read_remittance_source(source)
    path = File.join(Dir.mktmpdir, "posting_plan_test.835")
    File.write(path, source)
    Corvid::Rcm::Edi835Reader.read(path)
  end

  def unbalanced_remittance_from_fixture(scenario)
    source = File.read(File.join(FIXTURES, "#{scenario}.835"))
                 .sub("CAS*CO*45*50.00~", "CAS*CO*45*51.00~")
    read_remittance_source(source)
  end

  def service_line_paid_mismatch?(claim)
    return false if claim.services.empty?

    claim.services.sum(BigDecimal(0), &:paid_amount) != claim.paid_amount
  end

  def assert_balanced_claim_posting(plan, claim)
    assert_nil unbalanced_for(plan, claim.claim_identifier),
               "expected #{claim.claim_identifier} to be absent from unbalanced"

    entries = entries_for(plan, claim.claim_identifier)
    refute_empty entries

    payment_total = entries.select { |e| e.kind == :payer_payment }.sum(BigDecimal(0), &:amount)
    adjustment_total = entries.reject { |e| e.kind == :payer_payment }.sum(BigDecimal(0), &:amount)

    assert_equal claim.paid_amount, payment_total
    assert_equal claim.total_adjustment_amount, adjustment_total
    assert_equal claim.billed_amount, entries.sum(BigDecimal(0), &:amount)

    claim.all_adjustments.each do |adjustment|
      matching = entries.count do |entry|
        entry.group_code == adjustment.group_code &&
          entry.reason_code == adjustment.reason_code &&
          entry.amount == adjustment.amount
      end
      assert_operator matching, :>=, 1,
                      "missing CAS #{adjustment.code} on #{claim.claim_identifier}"
    end
  end

  def assert_unbalanced_claim_posting(plan, claim)
    row = unbalanced_for(plan, claim.claim_identifier)
    refute_nil row, "expected #{claim.claim_identifier} in unbalanced"
    assert_equal claim.unexplained_amount, row.unexplained_amount
    assert_empty entries_for(plan, claim.claim_identifier)
  end

  def assert_reversal_claim_posting(plan, claim)
    if claim.paid_amount.positive? || !claim.balanced?
      assert_unbalanced_claim_posting(plan, claim)
      return
    end

    entries = entries_for(plan, claim.claim_identifier)
    refute_empty entries
    assert entries.all? { |entry| entry.kind == :reversal }
    assert_equal claim.billed_amount, entries.sum(BigDecimal(0), &:amount)
  end
end
