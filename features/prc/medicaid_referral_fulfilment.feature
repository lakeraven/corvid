Feature: Medicaid referral fulfilment after authorization
  As a PRC coordinator
  I need delivery facts recorded from outside the engine before billing
  So that claims are not mistaken for proof that care occurred

  # corvid#595: PrcReferral currently terminates at `authorized`. These scenarios
  # specify post-authorization fulfilment states anyway — they MUST fail until
  # fulfilment is modeled.

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And facility "fac_test" is a tribal health programme facility
    And a patient "pt_med_001" enrolled as AI/AN with a PRC case
    And a PRC referral "rf_med_001" for that case
    And an authorized Medicaid-funded referral "rf_med_001"

  # =============================================================================
  # EXTERNAL FULFILMENT INPUTS (not inferred from claims)
  # =============================================================================

  # Catches inferring delivery when a Medicaid claim is filed (claim-as-proof defect).
  Scenario: A Medicaid claim submission does not change fulfilment status
    Given no external fulfilment report has been received for the referral
    When a Medicaid claim is drafted for the referral
    Then the referral fulfilment status should be "awaiting_report"
    And fulfilment should not be inferred from the claim

  # Catches silent “delivered” when nobody reported outcome.
  Scenario: No external report leaves fulfilment awaiting
    Given no external fulfilment report has been received for the referral
    Then the referral fulfilment status should be "awaiting_report"
    And the referral should not be billable for delivered care

  # Catches ignoring specialist confirmation as the authoritative delivery signal.
  Scenario: Receiving specialist reports care delivered
    When an external fulfilment report arrives for the referral:
      | source              | outcome   | reported_at          | detail                    |
      | receiving_specialist | delivered | 2026-03-15T16:00:00Z | Patient seen; plan started |
    Then the referral fulfilment status should be "delivered"
    And the referral should be billable for delivered care

  # Catches treating patient no-show as still deliverable/billable.
  Scenario: Patient reports appointment not kept
    When an external fulfilment report arrives for the referral:
      | source  | outcome      | reported_at          | detail        |
      | patient | not_delivered | 2026-03-15T18:30:00Z | No-show cited |
    Then the referral fulfilment status should be "not_delivered"
    And the referral should not be billable for delivered care
    And the not delivered reason should include "no_show"
