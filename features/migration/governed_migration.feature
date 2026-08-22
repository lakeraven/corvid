Feature: Governed patient-data migration
  As the Data Governance Board
  I want every migration to require my consent before any data leaves
  So that sovereignty is enforced by the platform, not by trust

  Background:
    Given a tenant "tnt_brokenrock" with facility "fac_main_clinic"
    And a migration case for patient "pt_hero_1"

  Scenario: Consented migration relays the minimum-necessary bundle and records approval
    Given the Data Governance Board has consented to migrate "Condition, MedicationRequest"
    And a source bundle with a "Condition", a "MedicationRequest", and an "Observation"
    When the governed migration runs
    Then the migration succeeds
    And an "approved" determination is recorded on the case
    And the target received a "Condition" and a "MedicationRequest"
    And the target did not receive an "Observation"

  Scenario: Migration halts when the Board has not consented
    Given the Data Governance Board has not consented
    And a source bundle with a "Condition"
    When the governed migration runs
    Then the migration halts
    And no data is sent to the target
    And a "denied" determination is recorded on the case

  Scenario: Migration reports failure when the target relay fails
    Given the Data Governance Board has consented to migrate "Condition"
    And a source bundle with a "Condition"
    And the target will fail
    When the governed migration runs
    Then the migration halts

  Scenario: Migration halts when no source entries match the consented types
    Given the Data Governance Board has consented to migrate "Immunization"
    And a source bundle with a "Condition"
    When the governed migration runs
    Then the migration halts
    And no data is sent to the target

  Scenario: Missing consent records a denial without raising
    Given there is no Board consent
    And a source bundle with a "Condition"
    When the governed migration runs
    Then the migration halts
    And a "denied" determination is recorded on the case

  Scenario: Migration refuses a bundle whose patient does not match the case
    Given the Data Governance Board has consented to migrate "Condition"
    And a source bundle for a different patient
    When the governed migration is attempted
    Then the migration is refused for a patient mismatch
    And no data is sent to the target
