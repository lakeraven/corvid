Feature: Section 506 overpayment recovery
  As a tribal PRC program
  I need to recover overpayments from Medicare-participating providers
  So that federal funds are correctly applied per Section 506 of the MMA

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And the fee schedule contains:
      | cpt_code | locality | work_rvu | pe_rvu | mp_rvu | work_gpci | pe_gpci | mp_gpci | conversion_factor | effective_date |
      | 99213    | 01       | 1.30     | 1.59   | 0.09   | 1.000     | 0.988   | 0.825   | 32.74             | 2026-01-01     |
      | 99214    | 01       | 1.92     | 2.11   | 0.16   | 1.000     | 0.988   | 0.825   | 32.74             | 2026-01-01     |
      | 27447    | 01       | 20.77    | 18.26  | 4.58   | 1.000     | 0.988   | 0.825   | 32.74             | 2026-01-01     |
    And ZIP "98948" maps to locality "01"

  # =========================================================================
  # CLAIMS UPLOAD AND AUDIT
  # =========================================================================

  Scenario: Upload historical claims and identify overpayments
    Given the customer uploads paid claims:
      | cpt_code | zip   | paid_amount | provider_npi | provider_name      | date_of_service |
      | 99213    | 98948 | 185.00      | 1234567890   | Northwest Cardio   | 2025-06-15      |
      | 99214    | 98948 | 320.00      | 1234567890   | Northwest Cardio   | 2025-07-20      |
      | 27447    | 98948 | 45000.00    | 9876543210   | Valley Surgery     | 2025-08-01      |
    When the audit runs
    Then overpayments should be identified
    And the total overpayment should be greater than 0
    And overpayments should be grouped by provider

  Scenario: Correctly priced claims are excluded from recovery
    Given the customer uploads paid claims:
      | cpt_code | zip   | paid_amount | provider_npi | provider_name     | date_of_service |
      | 99213    | 98948 | 90.00       | 1234567890   | Honest Medical    | 2025-06-15      |
    When the audit runs
    Then no overpayments should be identified

  # =========================================================================
  # PROVIDER MEDICARE PARTICIPATION CHECK
  # =========================================================================

  Scenario: Verify provider is Medicare-participating
    Given provider NPI "1234567890" is Medicare-participating
    When I check Section 506 applicability for provider "1234567890"
    Then Section 506 should apply
    And the legal basis should include "Section 506 MMA 2003"
    And the legal basis should include "42 CFR 136.30"

  Scenario: Non-Medicare provider uses contractual basis only
    Given provider NPI "0000000000" is not Medicare-participating
    When I check Section 506 applicability for provider "0000000000"
    Then Section 506 should not apply
    And the legal basis should be "contractual"

  # =========================================================================
  # DEMAND LETTER GENERATION
  # =========================================================================

  Scenario: Generate Section 506 demand letter for Medicare provider
    Given an overpayment of 74.57 to Medicare-participating provider "Northwest Cardio"
    And the provider NPI is "1234567890"
    And the customer has signed recovery authorization "AUTH-2026-001"
    When I generate the demand letter
    Then the letter should cite "Section 506 of the Medicare Prescription Drug, Improvement, and Modernization Act of 2003"
    And the letter should cite "42 CFR 136.30"
    And the letter should state "payment in full"
    And the letter should state the overpayment amount as 74.57
    And the letter should state a 60-day return deadline
    And the letter should reference the False Claims Act
    And the letter should include the authorization reference "AUTH-2026-001"

  Scenario: Demand letter includes claim detail
    Given an overpayment to provider "Northwest Cardio" with claims:
      | cpt_code | date_of_service | paid_amount | medicare_rate | overpayment |
      | 99213    | 2025-06-15      | 185.00      | 110.43        | 74.57       |
      | 99214    | 2025-07-20      | 320.00      | 252.27        | 67.73       |
    When I generate the demand letter
    Then the letter should list 2 claims with dates and amounts
    And the total demanded should be 142.30

  Scenario: Demand letter for high-value surgical overpayment
    Given an overpayment to provider "Valley Surgery" with claims:
      | cpt_code | date_of_service | paid_amount  | medicare_rate | overpayment  |
      | 27447    | 2025-08-01      | 45000.00     | 1428.65       | 43571.35     |
    When I generate the demand letter
    Then the letter should cite Section 506
    And the total demanded should be 43571.35
    And the letter should offer an installment plan for amounts over 10000

  # =========================================================================
  # NON-TRIBAL (CONTRACTUAL BASIS) DEMAND LETTERS
  # =========================================================================

  Scenario: Rural facility demand uses contractual basis when no Section 506
    Given a non-tribal rural customer "Small Town CAH"
    And an overpayment of 74.57 to provider "Regional Specialist"
    And the referral authorization specified "payment limited to Medicare rates"
    When I generate the demand letter
    Then the letter should NOT cite Section 506
    And the letter should cite the referral authorization terms
    And the letter should state "per the terms of the referral authorization, payment is limited to the Medicare allowable rate"
    And the letter should state the overpayment amount as 74.57
    And the letter should state a 30-day return deadline

  Scenario: Rural facility demand without prior rate agreement
    Given a non-tribal rural customer "Small Town CAH"
    And an overpayment of 74.57 to provider "Regional Specialist"
    And no prior rate agreement exists
    When I generate the demand letter
    Then the letter should request voluntary refund
    And the letter should state the Medicare rate as the industry standard
    And the letter should NOT reference the False Claims Act
    And the tone should be "request" not "demand"

  Scenario: Tribal demand is stronger than rural demand
    Given a tribal customer "Yakama PRC" with Section 506 authority
    And a non-tribal customer "Rural CAH" without Section 506
    And both have the same overpayment of 142.30 to the same provider
    When I generate demand letters for both
    Then the tribal letter should cite Section 506 and FCA
    And the rural letter should cite contractual terms only
    And the tribal letter deadline should be 60 days
    And the rural letter deadline should be 30 days

  # =========================================================================
  # 60-DAY TIMELINE AND FALSE CLAIMS ACT
  # =========================================================================

  Scenario: Track 60-day return deadline from demand date
    Given a demand letter sent on "2026-05-01"
    Then the return deadline should be "2026-06-30"
    And interest should begin accruing on "2026-05-31"

  Scenario: Provider notified of False Claims Act exposure after 60 days
    Given a demand sent 61 days ago with no response
    When the deadline check runs
    Then a follow-up should be generated
    And the follow-up should warn of False Claims Act liability
    And the follow-up should state potential treble damages

  Scenario: Provider pays within 60 days — no FCA exposure
    Given a demand sent 30 days ago
    When the provider pays in full
    Then no FCA warning should be generated
    And the recovery should be marked "collected"

  # =========================================================================
  # INTEREST ACCRUAL
  # =========================================================================

  Scenario: Interest accrues after 30 days of non-payment
    Given a demand for 1000.00 sent 45 days ago with no payment
    When I calculate interest owed
    Then interest should be accrued for 15 days
    And the interest rate should be the current Treasury rate

  Scenario: No interest in first 30 days
    Given a demand for 1000.00 sent 20 days ago with no payment
    When I calculate interest owed
    Then no interest should be accrued

  # =========================================================================
  # FOLLOW-UP ESCALATION
  # =========================================================================

  Scenario: First follow-up at 30 days
    Given a demand sent 31 days ago with no response
    When the follow-up check runs
    Then a courtesy reminder should be generated
    And it should reference the original demand

  Scenario: Second follow-up at 60 days with FCA warning
    Given a demand sent 61 days ago with no response
    When the follow-up check runs
    Then an FCA warning letter should be generated

  Scenario: Escalation at 90 days
    Given a demand sent 91 days ago with no response
    When the follow-up check runs
    Then the case should be escalated
    And the customer should be notified
    And the escalation should recommend referral to OIG or tribal attorney

  # =========================================================================
  # COLLECTION AND PAYOUT
  # =========================================================================

  Scenario: Provider pays in full — payout queued
    Given a demand for 142.30 collected in full
    And the customer split is 70/30
    When payout is processed
    Then customer receives 42.69
    And we retain 99.61

  Scenario: Corvid subscriber gets 50/50 split
    Given a demand for 142.30 collected in full
    And the customer is a corvid subscriber with 50/50 split
    When payout is processed
    Then customer receives 71.15
    And we retain 71.15

  Scenario: Partial payment — payout on collected amount only
    Given a demand for 142.30 with 100.00 collected
    And the customer split is 70/30
    When payout is processed
    Then customer receives 30.00
    And we retain 70.00
    And remaining 42.30 continues in collection

  Scenario: Provider requests installment plan
    Given a demand for 43571.35 to provider "Valley Surgery"
    When the provider requests 6 monthly installments
    Then an installment plan should be created with 6 payments
    And each installment should be approximately 7261.89
    And payout to customer occurs after each installment clears

  # =========================================================================
  # BATCH OPERATIONS
  # =========================================================================

  Scenario: Generate demands for all overpaid providers in one audit
    Given an audit identifying overpayments to 3 providers
    And the customer authorizes recovery
    When I generate all demand letters
    Then 3 demand letters should be created
    And each should cite Section 506
    And each should have a 60-day deadline

  Scenario: Dashboard shows recovery pipeline
    Given demands in various states:
      | provider         | amount  | status    |
      | Northwest Cardio | 142.30  | sent      |
      | Valley Surgery   | 43571.35| follow_up |
      | Regional Imaging | 89.50   | collected |
    Then the pipeline should show total in collection as 43713.65
    And total collected as 89.50
    And total pending payout as calculated from collected
