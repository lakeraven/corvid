Feature: Medicare-Like Rate repricing
  As a PRC billing coordinator
  I need to know the correct Medicare rate for a procedure
  So that we don't overpay specialist providers

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And the fee schedule contains:
      | cpt_code | locality | work_rvu | pe_rvu | mp_rvu | work_gpci | pe_gpci | mp_gpci | conversion_factor | effective_date |
      | 99213    | 01       | 1.30     | 1.59   | 0.09   | 1.000     | 0.988   | 0.825   | 32.74             | 2026-01-01     |
      | 99214    | 01       | 1.92     | 2.11   | 0.16   | 1.000     | 0.988   | 0.825   | 32.74             | 2026-01-01     |
    And ZIP "98948" maps to locality "01"

  Scenario: Reprice a single CPT code
    When I reprice CPT "99213" in ZIP "98948"
    Then the Medicare rate should be calculated
    And the rate should be greater than 0

  Scenario: Calculate savings against billed amount
    When I reprice CPT "99213" in ZIP "98948" with billed amount 185.00
    Then the savings should be positive
    And the Medicare rate should be less than 185.00

  Scenario: Unknown CPT returns no result
    When I reprice CPT "XXXXX" in ZIP "98948"
    Then no rate should be found

  Scenario: Unknown ZIP returns no result
    When I reprice CPT "99213" in ZIP "00000"
    Then no rate should be found

  Scenario: Batch reprice multiple claims
    When I batch reprice:
      | cpt_code | zip   | billed_amount |
      | 99213    | 98948 | 185.00        |
      | 99214    | 98948 | 320.00        |
    Then 2 claims should be repriced
    And each result should have a Medicare rate

  Scenario: Audit identifies total overpayment
    When I audit these claims:
      | cpt_code | zip   | billed_amount |
      | 99213    | 98948 | 185.00        |
      | 99214    | 98948 | 320.00        |
    Then the audit should show total overpayment greater than 0
    And the audit should report 2 claims analyzed
