Feature: PRC Authorization Wizard
  As a care coordinator
  I want a step-by-step wizard for creating PRC referrals
  So that all required information is captured per 42 CFR 136.61

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_wiz_001" with a PRC case
    And a wizard is initialized for the patient

  # =============================================================================
  # WIZARD NAVIGATION
  # =============================================================================

  Scenario: Wizard displays progress indicator
    When I start the authorization wizard for patient "John Doe"
    Then I should see the wizard progress indicator
    And I should see step "Patient Selection" as current
    And I should see steps:
      | Patient Selection    |
      | Clinical Information |
      | Alternate Resources  |
      | Review               |

  Scenario: Wizard validates each step before proceeding
    Given I am on the patient selection step
    When I try to proceed without selecting a patient
    Then I should see a validation error "Patient is required"
    And I should remain on the patient selection step

  Scenario: User can navigate back to previous steps
    Given I am on the clinical information step
    When I click the "Back" button
    Then I should be on the patient selection step
    And my previous selections should be preserved

  # =============================================================================
  # STEP 1: PATIENT SELECTION
  # =============================================================================

  Scenario: Select patient for referral
    When I start the authorization wizard for patient "John Doe"
    Then I should see patient "John Doe" pre-selected
    And I should see the patient's eligibility status
    And I should see the patient's active coverage information

  Scenario: Patient eligibility warning
    Given patient "John Doe" has eligibility status "pending"
    When I start the authorization wizard for patient "John Doe"
    Then I should see a warning "Patient eligibility verification pending"

  # =============================================================================
  # STEP 2: CLINICAL INFORMATION
  # =============================================================================

  Scenario: Complete clinical information step
    Given I am on the clinical information step
    When I fill in the clinical information:
      | field                | value                          |
      | Service Requested    | Cardiology Consultation        |
      | Reason for Referral  | Chest pain evaluation          |
      | Medical Priority     | 2 - Urgent                     |
      | Estimated Cost       | 5000                           |
    And I select provider "Dr. Smith" as the referring provider
    And I click "Continue"
    Then I should be on the alternate resources step

  Scenario: Clinical justification required for high-cost referrals
    Given I am on the clinical information step
    And the wizard committee threshold is "$50,000"
    When I enter estimated cost of "$75,000"
    Then I should see wizard message "Clinical justification required for costs over $50,000"
    And the clinical justification field should be required

  Scenario: Medical priority selection
    Given I am on the clinical information step
    Then I should see medical priority options:
      | 1 - Emergency (Life-threatening)    |
      | 2 - Urgent (24-72 hours)            |
      | 3 - Routine (30 days)               |
      | 4 - Elective                        |

  # =============================================================================
  # STEP 3: ALTERNATE RESOURCES (42 CFR 136.61)
  # =============================================================================

  Scenario: Alternate resources step shows all payers
    Given I am on the alternate resources step
    Then I should see checkboxes for:
      | Medicare Part A      |
      | Medicare Part B      |
      | Medicaid             |
      | Private Insurance    |
      | VA Benefits          |
      | Workers' Compensation|
      | Auto Insurance       |
    And I can record status for each

  Scenario: Record enrollment status for alternate resources
    Given I am on the alternate resources step
    When I set "Medicare Part A" status to "Not Enrolled"
    And I set "Medicare Part B" status to "Not Enrolled"
    And I set "Medicaid" status to "Enrolled"
    Then "Medicaid" should show as requiring coordination of benefits

  Scenario: Private insurance requires additional details
    Given I am on the alternate resources step
    When I set "Private Insurance" status to "Enrolled"
    Then I should see fields for:
      | Payer Name     |
      | Policy Number  |
      | Group Number   |
      | Coverage Start |
      | Coverage End   |

  Scenario: Verify alternate resources exhaustion
    Given I am on the alternate resources step
    When I set all resources to "Not Enrolled" or "Exhausted"
    And I click "Continue"
    Then I should be on the review step
    And alternate resources should be marked as exhausted

  Scenario: Warning when coverage exists
    Given I am on the alternate resources step
    When I set "Medicaid" status to "Enrolled"
    And I click "Continue"
    Then I should see a warning "Active coverage found - coordination of benefits required"
    And I should see instructions for billing primary payer first

  Scenario: Auto-verify enrollment status
    Given I am on the alternate resources step
    When I click "Verify All Enrollment"
    Then enrollment verification should run for all resources
    And I should see updated status for each resource

  # =============================================================================
  # STEP 4: REVIEW & SUBMIT
  # =============================================================================

  Scenario: Review step displays all entered information
    Given I have completed all wizard steps
    When I am on the review step
    Then I should see a summary including:
      | Patient DFN          | 12345                       |
      | Service Requested    | Cardiology Consultation     |
      | Reason for Referral  | Chest pain evaluation       |
      | Medical Priority     | 2                           |
      | Estimated Cost       | 5000                        |
      | Alternate Resources  | Verified                    |

  Scenario: Submit referral from wizard
    Given I have completed all wizard steps
    And I am on the review step
    When I click "Submit Referral"
    Then a PRC referral should be created
    And the referral status should be "submitted"
    And I should see a success message "Referral submitted successfully"

  Scenario: Edit information from review step
    Given I am on the review step
    When I click "Edit" next to "Clinical Information"
    Then I should be on the clinical information step
    And my information should be preserved

  # =============================================================================
  # COMPLETE WIZARD FLOW
  # =============================================================================

  Scenario: Complete wizard flow
    Given I start the authorization wizard for patient "John Doe"
    When I complete the patient selection step
    And I complete the clinical information step with:
      | Service Requested   | Cardiology Consultation |
      | Reason for Referral | Chest pain evaluation   |
      | Medical Priority    | 2                       |
      | Estimated Cost      | 5000                    |
    And I complete the alternate resources step
    And I review and submit
    Then a PRC referral should be created
    And it should be in "submitted" status
    And wizard referral should have alternate resource checks for all types

  Scenario: Referral requires committee review for high cost
    Given I start the authorization wizard for patient "John Doe"
    And the wizard committee threshold is "$50,000"
    When I complete all steps with estimated cost "$75,000"
    And I submit the wizard referral
    Then the referral should be flagged for committee review
    And I should see a message "Referral requires committee review due to cost"

  # =============================================================================
  # ACCESSIBILITY (WCAG 2.1 AA)
  # =============================================================================

  @accessibility @wip
  Scenario: Keyboard navigation
    Given I am using keyboard navigation
    When I navigate the wizard
    Then I can complete the wizard using Tab and Enter keys only
    And focus should move logically through form fields
    And I can return to previous steps using Shift+Tab

  @accessibility @wip
  Scenario: Screen reader compatibility
    Given I am using a screen reader
    When I navigate the wizard
    Then all form fields should have accessible labels
    And error messages should be announced
    And the current step should be announced
    And progress should be communicated

  @accessibility
  Scenario: Form field labels and descriptions
    When I start the authorization wizard
    Then all input fields should have visible labels
    And required fields should be marked with an asterisk
    And help text should be associated with fields using aria-describedby

  # =============================================================================
  # ERROR HANDLING
  # =============================================================================

  Scenario: Save progress on error
    Given I am on the clinical information step
    And I have entered some information
    When a network error occurs
    Then my entered information should be preserved
    And I should see wizard error "Unable to save. Please try again."

  Scenario: Validation errors display clearly
    Given I am on the clinical information step
    When I submit without required fields
    Then I should see validation errors next to each field
    And the first error field should receive focus
    And errors should be summarized at the top of the form

  # =============================================================================
  # DRAFT MANAGEMENT
  # =============================================================================

  @wip
  Scenario: Auto-save wizard progress
    Given I am on the clinical information step
    When I enter clinical information
    Then my progress should be auto-saved
    And I should see "Draft saved" indicator

  @wip
  Scenario: Resume incomplete wizard
    Given I have an incomplete wizard draft for patient "John Doe"
    When I start the authorization wizard for patient "John Doe"
    Then I should be prompted to resume or start over
    And selecting "Resume" should restore my progress
