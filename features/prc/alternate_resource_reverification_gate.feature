# frozen_string_literal: true

Feature: Alternate resource re-verification gates
  Authorization and claim submission must re-verify stale checks before relying on them,
  and must explain which resource is not current when re-verification fails.

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_test_001" with a PRC case
    And a PRC referral "rf_reverif_gate_001" for that case

  Scenario: Committee sync names medicaid not current when stale for authorization date
    Given the referral is in committee review state
    And today's date is "2025-07-01"
    And all twelve alternate resource checks are current except "medicaid" verified 31 days ago
    And the adapter cannot re-verify "medicaid" eligibility
    Given a finalized committee approval exists for the referral
    When committee sync is attempted for the approved review
    Then the sync should be blocked with blocker "medicaid: not current"
    And the sync blockers should not be only "referral: committee_review"

  Scenario: Linked draft claim cannot bypass submission gate with a plain status update
    Given an authorized PRC referral "REF-CU-BYPASS" for patient "pt_cu_bypass"
    And a draft claim linked to that referral with service date "2025-06-15"
    When the billing coordinator updates the claim status to "submitted" without submit!
    Then the claim update should be rejected
    And the claim should remain in draft with no submitted_at

  Scenario: Linked claim in error cannot bypass submission gate to submitted
    Given an authorized PRC referral "REF-CU-ERROR" for patient "pt_cu_error"
    And a draft claim linked to that referral with service date "2025-06-15"
    And the claim status is "error" with no submitted_at
    When the billing coordinator updates the claim status to "submitted" without submit!
    Then the claim update should be rejected
    And the claim should remain in "error" with no submitted_at

  Scenario: mark_submitted! refuses when the linked referral is not authorized
    Given a draft claim linked to referral "REF-CU-MARK" for patient "pt_cu_mark" with service date "2025-06-15"
    When mark_submitted! is attempted for claim identifier "CLM-CU-MARK"
    Then mark_submitted! should be refused for unauthorized referral
    And the claim should remain in draft with no submitted_at

  Scenario: Linked draft cannot reach denied via plain save
    Given an authorized PRC referral "REF-CU-DENIED" for patient "pt_cu_denied"
    And a draft claim linked to that referral with service date "2025-06-15"
    When the billing coordinator updates the claim status to "denied" without submit!
    Then the claim update should be rejected
    And the claim should remain in draft with no submitted_at

  Scenario: Linked draft with submitted_at preset cannot bypass gate to submitted
    Given an authorized PRC referral "REF-CU-STAMP" for patient "pt_cu_stamp"
    And a draft claim linked to that referral with service date "2025-06-15"
    And the claim has submitted_at set without going through submit!
    When the billing coordinator updates the claim status to "submitted" without submit!
    Then the claim update should be rejected
    And the claim should remain in draft with no submitted_at

  Scenario: Rejected linked claim cannot be resubmitted via plain save
    Given an authorized PRC referral "REF-CU-RESUB" for patient "pt_cu_resub"
    And a submitted claim linked to that referral with service date "2025-06-15"
    And the claim status is "rejected"
    When the billing coordinator updates the claim status to "submitted" without submit!
    Then the claim update should be rejected
    And the claim should remain in "rejected"

  Scenario: Historical paid import does not stamp submitted_at
    Given an authorized PRC referral "REF-CU-IMPORT" for patient "pt_cu_import"
    When a paid claim is imported for that referral with service date "2025-06-15"
    Then the imported claim should have no submitted_at

  Scenario: Legacy submitted claim with nil submitted_at can be marked paid
    Given an authorized PRC referral "REF-CU-LEGACY" for patient "pt_cu_legacy"
    And a legacy submitted claim linked to that referral with service date "2025-06-15"
    When mark_paid! is applied to the claim for amount "80.00"
    Then the claim should be paid
