# frozen_string_literal: true

# Medicaid end-to-end referral scenarios (gate-authored). Steps assert domain
# behavior that is not yet implemented on PrcReferral fulfilment, primary payer
# designation, claim↔referral association, and federal share (corvid#595, #546).

module MedicaidReferralSteps
  def advance_eligibility_through_management_approval!(referral, approver: "pr_mgr_001")
    referral.submit! unless referral.submitted?
    referral.begin_eligibility_review! unless referral.eligibility_review?
    Corvid::EligibilityChecklistService.populate!(referral)
    Corvid::EligibilityChecklistService.verify_item!(referral, :application_complete, by: "pr_staff_001")
    # The payer-eligibility-check mechanism itself (and its "source" value)
    # is the Staff completes application... scenario's own assertion
    # target, exercised there via "staff runs a payer eligibility check
    # ...and finds coverage" (which seeds adapter coverage first). This
    # helper is plain arrangement for the Medicaid-payer scenarios below
    # it, which don't seed coverage data, so it verifies manually rather
    # than depending on a 270/271 check that would find nothing here.
    Corvid::EligibilityChecklistService.check_payer_eligibility!(referral)
    Corvid::EligibilityChecklistService.verify_item!(referral, :insurance_verified, source: "manual") unless
      referral.reload.eligibility_checklist&.insurance_verified
    Corvid::EligibilityChecklistService.verify_item!(referral, :clinical_necessity_documented, source: "manual")
    referral.reload.request_management_approval! if referral.may_request_management_approval?
    referral.pending_approval_by = approver
    referral.approve_management! if referral.may_approve_management?
    referral.reload
  end

  def referral_for(identifier)
    Corvid::PrcReferral.find_by!(referral_identifier: identifier)
  end

  def require_medicaid_referral_workflow!
    return if defined?(Corvid::MedicaidReferralWorkflow)

    flunk "Corvid::MedicaidReferralWorkflow is not implemented — builder owns Medicaid payer path"
  end

  def require_referral_fulfilment!
    return if defined?(Corvid::ReferralFulfilment)

    flunk "Corvid::ReferralFulfilment is not implemented — corvid#595"
  end

  def require_federal_share_classifier!
    return if defined?(Corvid::MedicaidFederalShareClassifier)

    flunk "Corvid::MedicaidFederalShareClassifier is not implemented — corvid#546"
  end

  def require_referral_billing_reconciliation!
    return if defined?(Corvid::ReferralBillingReconciliation)

    flunk "Corvid::ReferralBillingReconciliation is not implemented"
  end

  # Test-only arrangement for "no external fulfilment report has been
  # received" fixtures. PR #598 review: production code (
  # Corvid::ReferralFulfilment) must never expose a way to erase
  # fulfilment history, so this lives here instead of as a class method
  # on that service.
  def clear_fulfilment_reports_for_test!(referral)
    referral.fulfilment_reports.destroy_all
  end
end

World(MedicaidReferralSteps)

Given("facility {string} is a tribal health programme facility") do |facility_id|
  @tribal_facility_identifier = facility_id
  @tribal_health_programme = true
end

Given("a patient {string} enrolled as AI\\/AN with a PRC case") do |patient_id|
  @case = Corvid::Case.create!(
    patient_identifier: patient_id,
    facility_identifier: @facility
  )
  Corvid.adapter.add_patient(patient_id,
    display_name: "TEST,PATIENT #{patient_id}",
    dob: Date.new(1980, 1, 1),
    sex: "F",
    ssn_last4: "1111",
    american_indian_alaska_native: true
  )
end

Given("the referral requests outside specialty care {string}") do |_service_label|
  Corvid.adapter.add_referral(@referral.referral_identifier,
    patient_identifier: @case.patient_identifier,
    status: "submitted",
    estimated_cost: @referral.estimated_cost&.to_d,
    service_requested: "Outside specialty care"
  )
end

Given("the medicaid referral has completed eligibility and management approval") do
  advance_eligibility_through_management_approval!(@referral)
end

When("Medicaid primary payer is recorded for the referral") do
  require_medicaid_referral_workflow!
  Corvid::MedicaidReferralWorkflow.record_medicaid_primary_payer!(@referral)
end

When("the referral completes authorization as Medicaid-funded") do
  require_medicaid_referral_workflow!
  Corvid::MedicaidReferralWorkflow.authorize_with_medicaid!(@referral)
  @referral.reload
end

When("the referral completes authorization as programme-funded") do
  @referral.verify_alternate_resources! if @referral.may_verify_alternate_resources?
  @referral.complete_priority_assignment! if @referral.may_complete_priority_assignment?
  @referral.authorize! if @referral.may_authorize?
  Corvid::BudgetAvailabilityService.reserve_funds_if_available(
    @referral.referral_identifier,
    @referral.estimated_cost
  )
  @referral.reload
end

Then("the referral primary payer should be {string}") do |payer|
  require_medicaid_referral_workflow!
  assert_equal payer, Corvid::MedicaidReferralWorkflow.primary_payer(@referral)
end

Then("no programme appropriation should exist for the referral") do
  assert_nil Corvid.adapter.get_obligation_by_referral(@referral.referral_identifier),
    "Expected no programme appropriation for #{@referral.referral_identifier}"
end

Then("a programme appropriation should exist for the referral") do
  refute_nil Corvid.adapter.get_obligation_by_referral(@referral.referral_identifier),
    "Expected programme appropriation for #{@referral.referral_identifier}"
end

Then("the appropriation amount should be {string}") do |amount|
  obl = Corvid.adapter.get_obligation_by_referral(@referral.referral_identifier)
  refute_nil obl
  expected = amount.gsub(/[$,]/, "").to_f
  assert_in_delta expected, obl[:amount].to_f, 0.01
end

# --- Fulfilment (corvid#595) -------------------------------------------------

Given("an authorized Medicaid-funded referral {string}") do |referral_id|
  @referral = referral_for(referral_id)
  require_medicaid_referral_workflow!
  Corvid::MedicaidReferralWorkflow.bootstrap_authorized_medicaid_referral!(@referral)
  @referral.reload
end

Given("an authorized Medicaid-funded referral {string} with delivered care") do |referral_id|
  @referral = referral_for(referral_id)
  require_medicaid_referral_workflow!
  Corvid::MedicaidReferralWorkflow.bootstrap_authorized_medicaid_referral!(@referral)
  require_referral_fulfilment!
  Corvid::ReferralFulfilment.record_external_report!(
    @referral,
    source: "receiving_specialist",
    outcome: "delivered",
    reported_at: Time.zone.parse("2026-03-15T16:00:00Z"),
    detail: "Fixture delivery for billing scenarios"
  )
  @referral.reload
end

Given("an authorized Medicaid-funded referral {string} for patient {string}") do |referral_id, patient_id|
  @case = Corvid::Case.find_by!(patient_identifier: patient_id, facility_identifier: @facility)
  @referral = Corvid::PrcReferral.create!(
    case: @case,
    referral_identifier: referral_id,
    facility_identifier: @facility
  )
  require_medicaid_referral_workflow!
  Corvid::MedicaidReferralWorkflow.bootstrap_authorized_medicaid_referral!(@referral)
end

Given("no external fulfilment report has been received for the referral") do
  require_referral_fulfilment!
  clear_fulfilment_reports_for_test!(@referral)
end

Given("no external fulfilment report has been received for referral {string}") do |referral_id|
  require_referral_fulfilment!
  clear_fulfilment_reports_for_test!(referral_for(referral_id))
end

When("a Medicaid claim is drafted for the referral") do
  @claim_submission = Corvid::ClaimSubmission.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: @referral.case.patient_identifier,
    referral_identifier: @referral.referral_identifier,
    claim_type: "professional",
    status: "draft",
    billed_amount: 425.00,
    payer_identifier: "medicaid",
    service_date: Date.current,
    provider_identifier: "pr_out_001"
  )
end

Then("the referral fulfilment status should be {string}") do |status|
  require_referral_fulfilment!
  assert_equal status, Corvid::ReferralFulfilment.status(@referral)
end

Then("fulfilment should not be inferred from the claim") do
  require_referral_fulfilment!
  refute Corvid::ReferralFulfilment.inferred_from_claim?(@referral, @claim_submission),
    "Fulfilment must not be inferred from claim presence"
end

Then("the referral should not be billable for delivered care") do
  require_referral_fulfilment!
  refute Corvid::ReferralFulfilment.billable_for_delivered_care?(@referral)
end

Then("the referral should be billable for delivered care") do
  require_referral_fulfilment!
  assert Corvid::ReferralFulfilment.billable_for_delivered_care?(@referral)
end

When("an external fulfilment report arrives for the referral:") do |table|
  require_referral_fulfilment!
  row = table.hashes.first
  Corvid::ReferralFulfilment.record_external_report!(
    @referral,
    source: row["source"],
    outcome: row["outcome"],
    reported_at: Time.zone.parse(row["reported_at"]),
    detail: row["detail"]
  )
end

Then("the not delivered reason should include {string}") do |token|
  require_referral_fulfilment!
  reasons = Corvid::ReferralFulfilment.not_delivered_reasons(@referral)
  assert reasons.any? { |r| r.include?(token) },
    "Expected not_delivered reasons to include #{token}, got #{reasons.inspect}"
end

# --- Billing -----------------------------------------------------------------

Given("the referral service site is outside specialist {string}") do |provider_id|
  @outside_provider_identifier = provider_id
  Corvid.adapter.add_referral(@referral.referral_identifier,
    patient_identifier: @referral.case.patient_identifier,
    rendering_provider_identifier: provider_id,
    service_site: "non_tribal_specialist"
  )
end

When("I submit a Medicaid professional claim for the referral with:") do |table|
  require_referral_fulfilment!
  unless defined?(Corvid::MedicaidReferralBilling)
    flunk "Corvid::MedicaidReferralBilling is not implemented"
  end
  row = table.hashes.first
  charge = row["charge"].gsub(/[$,]/, "").to_f
  @claim_submission = Corvid::MedicaidReferralBilling.submit_claim!(
    referral: @referral,
    cpt_code: row["cpt_code"],
    charge: charge,
    provider_identifier: @outside_provider_identifier || "pr_out_001"
  )
end

When("I try to submit a Medicaid professional claim for referral {string}") do |referral_id|
  referral = referral_for(referral_id)
  require_referral_fulfilment!
  begin
    @claim_submission = Corvid::MedicaidReferralBilling.submit_claim!(
      referral: referral,
      cpt_code: "99243",
      charge: 425.00,
      provider_identifier: "pr_out_001"
    )
    @claim_rejected = false
  rescue Corvid::MedicaidReferralBilling::SubmissionRejected => e
    @claim_rejected = true
    @claim_rejection_reason = e.message
  end
end

Then("the claim submission should belong to PRC referral {string}") do |referral_id|
  referral = referral_for(referral_id)
  assert_equal referral.id, @claim_submission.prc_referral_id,
    "ClaimSubmission must belong_to PrcReferral, not only store referral_identifier"
end

Then("the claim payer should be {string}") do |payer|
  assert_equal payer, @claim_submission.payer_identifier
end

Then("the claim submission patient should be {string}") do |patient_id|
  assert_equal patient_id, @claim_submission.patient_identifier
end

Then("the claim submission should be rejected") do
  assert @claim_rejected, "Expected claim submission to be rejected"
end

Then("the rejection reason should include {string}") do |fragment|
  assert_includes @claim_rejection_reason.to_s, fragment
end

When("federal share is classified for the claim") do
  require_federal_share_classifier!
  @federal_share_determination = Corvid::MedicaidFederalShareClassifier.classify!(@claim_submission,
    tribal_facility_identifier: @tribal_facility_identifier || @facility,
    patient_identifier: @referral.case.patient_identifier
  )
end

Then("the federal share determination should be {int} percent federal and {int} percent state") do |fed, state|
  require_federal_share_classifier!
  assert_equal fed, @federal_share_determination.federal_percent
  assert_equal state, @federal_share_determination.state_percent
end

Then("the federal share basis should include {string}") do |token|
  require_federal_share_classifier!
  assert_includes @federal_share_determination.basis_tokens, token
end

Then("the federal share determination should be recorded") do
  require_federal_share_classifier!
  refute_nil @federal_share_determination
end

Then("the federal share basis should note {string}") do |token|
  require_federal_share_classifier!
  assert_includes @federal_share_determination.basis_tokens, token
end

Given("a Medicaid claim submission exists for referral {string} with status {string}") do |referral_id, status|
  referral = referral_for(referral_id)
  @claim_submission = Corvid::ClaimSubmission.create!(
    tenant_identifier: @tenant,
    facility_identifier: @facility,
    patient_identifier: referral.case.patient_identifier,
    referral_identifier: referral.referral_identifier,
    claim_identifier: "CLM_MED_#{referral_id}",
    claim_type: "professional",
    status: status,
    billed_amount: 425.00,
    paid_amount: status == "paid" ? 380.00 : nil,
    payer_identifier: "medicaid",
    service_date: Date.current,
    provider_identifier: "pr_out_001",
    submitted_at: Time.current
  )
end

Given("a remittance includes Medicaid payment for that claim with amount {string}") do |amount|
  paid = amount.gsub(/[$,]/, "").to_f
  Corvid.adapter.add_remittance("REM_MED_#{@claim_submission.claim_identifier}", {
    remittance_identifier: "REM_MED_#{@claim_submission.claim_identifier}",
    payer_name: "State Medicaid",
    payment_date: Date.current,
    total_paid: paid,
    line_items: [
      {
        claim_identifier: @claim_submission.claim_identifier,
        paid_amount: paid,
        adjustment_amount: 45.00,
        patient_responsibility: 0
      }
    ]
  })
end

When("I reconcile the referral billing") do
  require_referral_billing_reconciliation!
  @reconciliation = Corvid::ReferralBillingReconciliation.reconcile!(
    referral: @referral,
    claim: @claim_submission
  )
end

Then("the claim submission should be marked paid with amount {string}") do |amount|
  expected = amount.gsub(/[$,]/, "").to_f
  @claim_submission.reload
  assert_equal "paid", @claim_submission.status
  assert_in_delta expected, @claim_submission.paid_amount.to_f, 0.01
end

Then("the referral billing reconciliation should be {string}") do |state|
  assert_equal state, @reconciliation.status
end

Then("the reconciliation should reference delivered fulfilment for {string}") do |referral_id|
  assert_equal referral_id, @reconciliation.referral_identifier
  assert @reconciliation.fulfilment_verified,
    "Reconciliation must confirm delivered fulfilment, not payment alone"
end
