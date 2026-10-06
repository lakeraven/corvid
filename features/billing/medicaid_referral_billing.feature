Feature: Medicaid referral billing remittance and federal share
  As a tribal billing coordinator
  I need Medicaid claims tied to referrals with correct federal share and reconciliation
  So that AI/AN beneficiaries at tribal programmes are billed and reconciled accurately

  # Federal match — gate legal review (primary source not re-fetched this session):
  #
  # Prong A (VERIFIED by statute text commonly published at SSA Title XIX):
  #   Social Security Act §1905(b) — for medical assistance for services received
  #   through an Indian Health Service facility or through a facility of a tribe or
  #   tribal organization (as defined in section 4 of the Indian Health Care
  #   Improvement Act), the Federal medical assistance percentage is 100 percent.
  #   Builder MUST confirm current §1905(b) at https://www.ssa.gov/OP_Home/ssact/title19/1905.htm
  #   before merging federal-share classification (corvid#546 / PR #547).
  #
  # Prong B (UNVERIFIED this session): CMS/IHS guidance extending 100% FMAP to
  # services through non-IHS providers under care coordination for referred care.
  # Scenarios below separate tribal-facility-ordered services from pure outside
  # specialist claims until Prong B is cited.

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And facility "fac_test" is a tribal health programme facility
    And the billing adapter is configured
    And a patient "pt_med_001" enrolled as AI/AN with a PRC case
    And a PRC referral "rf_med_001" for that case
    And an authorized Medicaid-funded referral "rf_med_001" with delivered care

  # =============================================================================
  # CLAIM — association to referral (not patient alone)
  # =============================================================================

  # Catches orphan claims that cannot be audited back to the authorization that permitted care.
  Scenario: Medicaid claim is associated with the PRC referral it bills
    When I submit a Medicaid professional claim for the referral with:
      | cpt_code | charge  |
      | 99243    | 425.00  |
    Then the claim submission should belong to PRC referral "rf_med_001"
    And the claim payer should be "medicaid"
    And the claim submission patient should be "pt_med_001"

  # Catches billing before fulfilment records delivery.
  Scenario: Medicaid claim cannot be submitted without delivered fulfilment
    Given an authorized Medicaid-funded referral "rf_med_002" for patient "pt_med_001"
    And no external fulfilment report has been received for referral "rf_med_002"
    When I try to submit a Medicaid professional claim for referral "rf_med_002"
    Then the claim submission should be rejected
    And the rejection reason should include "fulfilment"

  # =============================================================================
  # FEDERAL SHARE CLASSIFICATION (corvid#546)
  # =============================================================================

  # Catches applying standard state FMAP to AI/AN tribal-facility-ordered Medicaid services.
  Scenario: Tribal facility context yields one hundred percent federal share on Medicaid claim
    When I submit a Medicaid professional claim for the referral with:
      | cpt_code | charge  |
      | 99243    | 425.00  |
    And federal share is classified for the claim
    Then the federal share determination should be 100 percent federal and 0 percent state
    And the federal share basis should include "SSA 1905(b)"
    And the federal share basis should include "tribal_facility"
    And the federal share basis should include "ai_an_beneficiary"

  # Catches assuming Prong B without documentation when billing an outside specialist only.
  Scenario: Outside specialist claim records federal share basis pending care coordination citation
    Given the referral service site is outside specialist "pr_out_99243"
    When I submit a Medicaid professional claim for the referral with:
      | cpt_code | charge  |
      | 99243    | 425.00  |
    And federal share is classified for the claim
    Then the federal share determination should be recorded
    And the federal share basis should note "care_coordination_prong_unverified"

  # =============================================================================
  # REMITTANCE AND RECONCILIATION
  # =============================================================================

  # Catches marking paid without tying remittance to referral fulfilment and claim.
  Scenario: Medicaid remittance reconciles payment to delivered referral care
    Given a Medicaid claim submission exists for referral "rf_med_001" with status "accepted"
    And a remittance includes Medicaid payment for that claim with amount "$380.00"
    When I reconcile the referral billing
    Then the claim submission should be marked paid with amount "$380.00"
    And the referral billing reconciliation should be "reconciled"
    And the reconciliation should reference delivered fulfilment for "rf_med_001"

  # Catches leaving programme appropriation reserved when Medicaid paid (double-counting).
  Scenario: Medicaid payment does not create a programme appropriation obligation
    Given a Medicaid claim submission exists for referral "rf_med_001" with status "paid"
    When I reconcile the referral billing
    Then no programme appropriation should exist for the referral
