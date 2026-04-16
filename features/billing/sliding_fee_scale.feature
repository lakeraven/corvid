@billing @ulster-rfp
Feature: Sliding Fee Scale
  As a billing administrator
  I want to configure sliding fee schedules based on income
  So that uninsured patients pay reduced fees based on Federal Poverty Level

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And the billing adapter is configured

  # =============================================================================
  # FEE SCHEDULE CONFIGURATION
  # =============================================================================

  Scenario: Create a sliding fee schedule with FPL tiers
    When I create a fee schedule "Immunization Sliding Fee" for program "immunization" with tiers:
      | fpl_max | discount_percent |
      | 100     | 100              |
      | 150     | 75               |
      | 200     | 50               |
      | 250     | 25               |
    Then the fee schedule should be active
    And it should have 4 discount tiers

  # =============================================================================
  # DISCOUNT CALCULATION
  # =============================================================================

  Scenario: Patient at 100% FPL receives free service
    Given a fee schedule exists with standard FPL tiers
    When I calculate the fee for a "$100.00" service for a patient at 80% FPL
    Then the discounted amount should be "$0.00"

  Scenario: Patient at 150% FPL receives 75% discount
    Given a fee schedule exists with standard FPL tiers
    When I calculate the fee for a "$100.00" service for a patient at 120% FPL
    Then the discounted amount should be "$25.00"

  Scenario: Patient at 200% FPL receives 50% discount
    Given a fee schedule exists with standard FPL tiers
    When I calculate the fee for a "$100.00" service for a patient at 180% FPL
    Then the discounted amount should be "$50.00"

  Scenario: Patient above all tiers pays full price
    Given a fee schedule exists with standard FPL tiers
    When I calculate the fee for a "$100.00" service for a patient at 300% FPL
    Then the discounted amount should be "$100.00"

  # =============================================================================
  # PROGRAM-SPECIFIC SCHEDULES
  # =============================================================================

  Scenario: Different programs have different fee schedules
    Given fee schedules exist for "immunization" and "std_clinic"
    When I look up the fee schedule for an immunization visit
    Then I should get the immunization fee schedule
    And not the STD clinic fee schedule

  Scenario: Only active and current fee schedules apply
    Given an expired fee schedule and a current fee schedule exist
    When I look up the current fee schedule
    Then only the current schedule should be returned
