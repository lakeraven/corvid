Feature: Facility CBSA wage area for institutional repricing
  As a PRC overpayment analyst
  I need outpatient hospital claims priced at the CMS wage area for the facility ZIP
  So that Medicare-equivalent amounts reflect local wage indexes instead of always using NATIONAL

  Background:
    Given a tenant "tnt_test" with facility "fac_test"

  Scenario: Rural synthetic facility uses its wage-area OPPS index; unmatched ZIP stays NATIONAL
    Given a zip-to-CBSA crosswalk CSV for fiscal year 2026:
      | zip   | cbsa |
      | 88202 | 12   |
    When I import the zip-to-CBSA crosswalk for fiscal year 2026 with release label "cucumber_synthetic"
    And the PRC facility dictionary maps code "RURA" to ZIP "88202"
    And the PRC facility dictionary maps code "NATL" to ZIP "88999"
    And CMS OPPS rates for calendar year 2026 are loaded for APC "5071"
    And the IPPS wage index for fiscal year 2026 locality "12" is 0.8500
    And the IPPS wage index for fiscal year 2026 locality "NATIONAL" is 1.0000
    And an outpatient PRC procedure "OUTPATIENT_CBSA" maps HCPCS "12345" to APC "5071"
    When I analyze an outpatient PRC obligation at facility "RURA" on "2026-03-01" with paid amount 5000.00
    Then the analyzer medicare equivalent should be 1513.55
    When I analyze an outpatient PRC obligation at facility "NATL" on "2026-03-01" with paid amount 5000.00
    Then the analyzer medicare equivalent should be 1780.65
