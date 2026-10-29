Feature: ZIP to CBSA crosswalk for PRC facility wage areas
  As a PRC overpayment analyst
  I need a facility ZIP to resolve to a CMS wage area (CBSA)
  So that inpatient and outpatient repricing can use per-area wage indexes

  Background:
    Given a tenant "tnt_test" with facility "fac_test"

  Scenario: Import a synthetic crosswalk and resolve a facility ZIP to CBSA
    Given a zip-to-CBSA crosswalk CSV for fiscal year 2026:
      | zip   | cbsa  |
      | 88101 | 98765 |
    When I import the zip-to-CBSA crosswalk for fiscal year 2026 with release label "cucumber_synthetic"
    And the PRC facility dictionary maps code "DEMO" to ZIP "88101"
    Then the CBSA for ZIP "88101" on "2026-01-15" should be "98765"
