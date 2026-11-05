Feature: Audit packet CBSA wage-area provenance
  As a tribal council auditor
  I need detail.csv and methodology.json to cite wage areas and crosswalk releases
  So that two facilities priced at different CMS wage indexes are distinguishable in the packet

  Background:
    Given a tenant "tnt_audit_wage_area" with facility "fac_test"

  Scenario: Recoverable detail CSV carries wage_area and crosswalk_release columns
    Given a zip-to-CBSA crosswalk CSV for fiscal year 2026:
      | zip   | cbsa |
      | 88202 | 12   |
    When I import the zip-to-CBSA crosswalk for fiscal year 2026 with release label "cucumber_audit_xw"
    And the PRC facility dictionary maps code "RURA" to ZIP "88202"
    And CMS OPPS rates for calendar year 2026 are loaded for APC "5071"
    And the IPPS wage index for fiscal year 2026 locality "12" is 0.8500
    And the IPPS wage index for fiscal year 2026 locality "NATIONAL" is 1.0000
    And an outpatient PRC procedure "OUTPATIENT_AUDIT" maps HCPCS "12345" to APC "5071"
    And I import and reanalyze an outpatient PRC obligation "OBL-AUDIT-CBSA" at facility "RURA" on "2026-03-01"
    When I export an audit packet detail CSV for tenant "tnt_audit_wage_area"
    Then the detail CSV row for obligation "OBL-AUDIT-CBSA" has wage_area "12"
    And the detail CSV row for obligation "OBL-AUDIT-CBSA" has crosswalk_release "cucumber_audit_xw"
