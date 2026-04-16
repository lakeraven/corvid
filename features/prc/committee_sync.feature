Feature: Committee review sync and eligibility via adapter
  As an EHR-agnostic Case engine
  Committee decisions and alternate resource checks should work through
  the adapter interface without direct RPMS dependencies

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_001" with a PRC case
    And a PRC referral "rf_comm_001" for that case

  Scenario: Committee approval syncs to adapter
    Given the referral is in committee review state
    When a committee review approves the referral for 75000
    Then the adapter should have the referral updated with approval status

  Scenario: All 12 alternate resource types verify via adapter
    When alternate resource checks are created for all resource types
    And all checks are verified via the adapter
    Then each check should have a status of enrolled or not_enrolled
