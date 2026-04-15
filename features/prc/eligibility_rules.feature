Feature: PRC eligibility rules
  As a PRC program
  I need formal eligibility rules evaluated via a rules engine
  So that eligibility determinations are consistent and auditable

  Scenario: Eligible patient passes all checks
    Given a patient with valid enrollment "ANLC-12345" in service area "Anchorage"
    And a referral for "chest pain evaluation" with urgency "routine" and coverage "IHS"
    When I evaluate eligibility
    Then the patient should be eligible
    And the message should include "Patient is eligible for PRC services"

  Scenario: Missing enrollment number fails enrollment check
    Given a patient with valid enrollment "" in service area "Anchorage"
    And a referral for "chest pain evaluation" with urgency "routine" and coverage "IHS"
    When I evaluate eligibility
    Then the patient should not be eligible
    And the message should include "Invalid or missing tribal enrollment number"

  Scenario: Invalid service area fails residency check
    Given a patient with valid enrollment "ANLC-12345" in service area "Portland"
    And a referral for "chest pain evaluation" with urgency "routine" and coverage "IHS"
    When I evaluate eligibility
    Then the patient should not be eligible
    And the message should include "outside coverage region"

  Scenario: Missing clinical justification fails necessity check
    Given a patient with valid enrollment "ANLC-12345" in service area "Anchorage"
    And a referral for "routine checkup" with urgency "routine" and coverage "IHS"
    When I evaluate eligibility
    Then the patient should not be eligible
    And the message should include "Insufficient clinical justification"

  Scenario: Invalid coverage type fails payor check
    Given a patient with valid enrollment "ANLC-12345" in service area "Anchorage"
    And a referral for "chest pain evaluation" with urgency "routine" and coverage "Unknown"
    When I evaluate eligibility
    Then the patient should not be eligible
    And the message should include "Unknown or invalid coverage type"

  Scenario: Emergent urgency with matching clinical presentation
    Given a patient with valid enrollment "ANLC-12345" in service area "Anchorage"
    And a referral for "severe chest pain" with urgency "emergent" and coverage "IHS"
    When I evaluate eligibility
    Then the patient should be eligible
