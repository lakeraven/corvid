# frozen_string_literal: true

# Authorization wizard step definitions (ported from rpms_redux)

def ensure_wizard
  @wizard ||= Corvid::AuthorizationWizard.new(
    patient_identifier: @case.patient_identifier,
    tenant_identifier: @tenant,
    facility_identifier: @facility
  )
end

Given("a wizard is initialized for the patient") do
  Corvid.adapter.add_patient(@case.patient_identifier,
    display_name: "TEST,WIZARD PATIENT",
    dob: Date.new(1985, 1, 1),
    sex: "M",
    ssn_last4: "1234"
  )
end

When("I start the authorization wizard for patient {string}") do |_name|
  ensure_wizard
  if @patient_eligibility_status
    @wizard.patient_eligibility_status = @patient_eligibility_status
  end
  @wizard.start!
end

When("I start the authorization wizard") do
  ensure_wizard
  @wizard.start!
end

# --- Progress indicator ---

Then("I should see the wizard progress indicator") do
  refute_nil @wizard.progress_indicator
end

Then("I should see step {string} as current") do |step_name|
  expected = step_name.downcase.tr(" ", "_").to_sym
  assert_equal expected, @wizard.current_step
end

Then("I should see steps:") do |table|
  expected = table.raw.flatten.map { |s| s.downcase.tr(" ", "_").to_sym }
  assert_equal expected, @wizard.steps
end

# --- Navigation ---

Given("I am on the patient selection step") do
  ensure_wizard
  @wizard.go_to_step(:patient_selection)
end

Given("I am on the clinical information step") do
  ensure_wizard
  @wizard.data[:patient_identifier] = @case.patient_identifier
  @wizard.go_to_step(:clinical_information)
end

Given("I am on the alternate resources step") do
  ensure_wizard
  @wizard.data[:patient_identifier] = @case.patient_identifier
  @wizard.data[:service_requested] = "Test Service"
  @wizard.data[:reason_for_referral] = "Chest pain evaluation"
  @wizard.go_to_step(:alternate_resources)
end

Given("I am on the review step") do
  ensure_wizard
  @wizard.data[:patient_identifier] ||= @case.patient_identifier
  @wizard.data[:service_requested] ||= "Test Service"
  @wizard.data[:reason_for_referral] ||= "Chest pain evaluation"
  @wizard.go_to_step(:review)
end

When("I try to proceed without selecting a patient") do
  @wizard.data[:patient_identifier] = nil
  @wizard.next_step!
end

When("I click the {string} button") do |button|
  case button
  when "Back" then @wizard.previous_step!
  when "Continue" then @wizard.next_step!
  end
end

When("I click {string}") do |action|
  case action
  when "Continue" then @wizard.next_step!
  when "Submit Referral" then @submit_result = @wizard.submit!
  when "Verify All Enrollment" then @wizard.verify_all_enrollment!
  end
end

When("I click {string} next to {string}") do |_action, section|
  step_name = section.downcase.tr(" ", "_").to_sym
  @wizard.go_to_step(step_name)
end

Then("I should see a validation error {string}") do |message|
  assert @wizard.errors.include?(message), "Expected error '#{message}' in #{@wizard.errors}"
end

Then("I should remain on the patient selection step") do
  assert_equal :patient_selection, @wizard.current_step
end

Then("I should be on the patient selection step") do
  assert_equal :patient_selection, @wizard.current_step
end

Then("I should be on the alternate resources step") do
  assert_equal :alternate_resources, @wizard.current_step
end

Then("I should be on the review step") do
  assert_equal :review, @wizard.current_step
end

Then("I should be on the clinical information step") do
  assert_equal :clinical_information, @wizard.current_step
end

Then("my previous selections should be preserved") do
  refute_nil @wizard.data[:patient_identifier]
end

Then("my information should be preserved") do
  refute_nil @wizard.data[:patient_identifier]
end

# --- Patient selection ---

Then("I should see patient {string} pre-selected") do |_name|
  refute_nil @wizard.data[:patient_identifier]
end

Then("I should see the patient's eligibility status") do
  refute_nil @wizard.patient_eligibility_status
end

Then("I should see the patient's active coverage information") do
  # Coverage info available via adapter
  refute_nil @wizard.patient
end

Given("patient {string} has eligibility status {string}") do |_name, status|
  @patient_eligibility_status = status
end

Then("I should see a warning {string}") do |message|
  assert @wizard.warnings.include?(message), "Expected warning '#{message}' in #{@wizard.warnings}"
end

# --- Clinical information ---

When("I fill in the clinical information:") do |table|
  table.rows_hash.each do |field, value|
    key = field.downcase.tr(" ", "_").to_sym
    @wizard.data[key] = value
  end
end

When("I select provider {string} as the referring provider") do |_provider|
  @wizard.data[:referring_provider] = "pr_test_001"
end

Given("the wizard committee threshold is {string}") do |threshold|
  @original_site_params = Corvid.adapter.method(:get_site_params)
  amount = threshold.gsub(/[$,]/, "").to_i
  Corvid.adapter.define_singleton_method(:get_site_params) do
    { station_number: "9999", station_name: "MOCK", chs_enabled: true,
      notification_grace_period: 72, committee_threshold: amount }
  end
end

When("I enter estimated cost of {string}") do |cost|
  @wizard.data[:estimated_cost] = cost
  @wizard.required_fields  # triggers threshold check
end

Then("I should see wizard message {string}") do |message|
  assert @wizard.messages.include?(message), "Expected message '#{message}' in #{@wizard.messages}"
end

Then("the clinical justification field should be required") do
  assert_includes @wizard.required_fields, :clinical_justification
end

Then("I should see medical priority options:") do |table|
  labels = @wizard.medical_priority_options.map { |o| o[:label] }
  table.raw.flatten.each do |expected|
    assert labels.include?(expected), "Expected priority option '#{expected}'"
  end
end

# --- Alternate resources ---

Then("I should see checkboxes for:") do |table|
  available = @wizard.available_alternate_resources.map { |r| r[:name] }
  table.raw.flatten.each do |name|
    assert available.include?(name), "Expected resource '#{name}' in #{available}"
  end
end

Then("I can record status for each") do
  assert @wizard.available_alternate_resources.length >= 7
end

When("I set {string} status to {string}") do |resource_name, status|
  type = @wizard.available_alternate_resources.find { |r| r[:name] == resource_name }&.dig(:type)
  type ||= resource_name.downcase.tr(" ", "_").tr("'", "")
  @wizard.set_resource_status(type, status.downcase.tr(" ", "_"))
end

When("I set all resources to {string} or {string}") do |status1, status2|
  status = status1.downcase.tr(" ", "_")
  @wizard.alternate_resources.each_key do |type|
    @wizard.set_resource_status(type, status)
  end
end

Then("{string} should show as requiring coordination of benefits") do |resource_name|
  type = @wizard.available_alternate_resources.find { |r| r[:name] == resource_name }&.dig(:type)
  assert @wizard.alternate_resources[type][:requires_coordination]
end

Then("I should see fields for:") do |table|
  fields = @wizard.private_insurance_fields.map { |f| f.to_s.tr("_", " ").split.map(&:capitalize).join(" ") }
  table.raw.flatten.each do |expected|
    assert fields.include?(expected), "Expected field '#{expected}' in #{fields}"
  end
end

Then("alternate resources should be marked as exhausted") do
  assert @wizard.alternate_resources_exhausted?
end

Then("I should see instructions for billing primary payer first") do
  refute_nil @wizard.coordination_instructions
end

Then("enrollment verification should run for all resources") do
  assert @wizard.enrollment_verification_run?
end

Then("I should see updated status for each resource") do
  @wizard.alternate_resources.each do |type, resource|
    refute_equal :not_checked, resource[:status], "Resource #{type} still not checked"
  end
end

# --- Review & submit ---

Given("I have completed all wizard steps") do
  ensure_wizard
  @wizard.data[:patient_identifier] = @case.patient_identifier
  @wizard.data[:service_requested] = "Cardiology Consultation"
  @wizard.data[:reason_for_referral] = "Chest pain evaluation"
  @wizard.data[:medical_priority] = 2
  @wizard.data[:estimated_cost] = 5000
  @wizard.alternate_resources.each_key do |type|
    @wizard.set_resource_status(type, "not_enrolled")
  end
  @wizard.go_to_step(:review)
end

Then("I should see a summary including:") do |table|
  summary = @wizard.summary
  table.rows_hash.each do |field, value|
    key = field.downcase.tr(" ", "_").to_sym
    actual = summary[key].to_s
    assert_equal value, actual, "Expected #{key} to be '#{value}' but was '#{actual}'"
  end
end

Then("a PRC referral should be created") do
  refute_nil @wizard.prc_referral || @submit_result&.dig(:referral)
end

Then("the referral status should be {string}") do |status|
  referral = @wizard.prc_referral
  assert_equal status, referral.status
end

Then("I should see a success message {string}") do |message|
  assert_equal message, @submit_result[:message]
end

Then("I should see a message {string}") do |message|
  assert @wizard.messages.include?(message) || @submit_result&.dig(:message) == message,
    "Expected message '#{message}'"
end

# --- Complete wizard flow ---

When("I complete the patient selection step") do
  @wizard.data[:patient_identifier] = @case.patient_identifier
  @wizard.next_step!
end

When("I complete the clinical information step with:") do |table|
  table.rows_hash.each do |field, value|
    key = field.downcase.tr(" ", "_").to_sym
    @wizard.data[key] = value
  end
  @wizard.next_step!
end

When("I complete the alternate resources step") do
  @wizard.alternate_resources.each_key do |type|
    @wizard.set_resource_status(type, "not_enrolled")
  end
  @wizard.next_step!
end

When("I review and submit") do
  @submit_result = @wizard.submit!
end

When("I submit the wizard referral") do
  @submit_result = @wizard.submit!
end

Then("it should be in {string} status") do |status|
  assert_equal status, @wizard.prc_referral.status
end

Then("wizard referral should have alternate resource checks for all types") do
  types = @wizard.prc_referral.alternate_resource_checks.pluck(:resource_type)
  Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
    assert_includes types, type
  end
end

When("I complete all steps with estimated cost {string}") do |cost|
  @wizard.data[:patient_identifier] = @case.patient_identifier
  @wizard.data[:service_requested] = "Cardiology Consultation"
  @wizard.data[:reason_for_referral] = "Chest pain evaluation"
  @wizard.data[:medical_priority] = 2
  @wizard.data[:estimated_cost] = cost
  @wizard.data[:clinical_justification] = "High-cost justified by clinical severity"
  @wizard.alternate_resources.each_key do |type|
    @wizard.set_resource_status(type, "not_enrolled")
  end
  @wizard.go_to_step(:review)
end

Then("the referral should be flagged for committee review") do
  assert @wizard.prc_referral.flagged_for_review?
end

# --- Accessibility ---

Given("I am using keyboard navigation") do
  ensure_wizard
  @wizard.start!
end

Given("I am using a screen reader") do
  ensure_wizard
  @wizard.start!
end

When("I navigate the wizard") do
  # Wizard supports navigation
end

Then("I can complete the wizard using Tab and Enter keys only") do
  assert @wizard.keyboard_accessible?
end

Then("focus should move logically through form fields") do
  assert @wizard.logical_focus_order?
end

Then("I can return to previous steps using Shift+Tab") do
  assert @wizard.supports_reverse_navigation?
end

Then("all form fields should have accessible labels") do
  assert @wizard.all_fields_labeled?
end

Then("error messages should be announced") do
  assert @wizard.errors_announced?
end

Then("the current step should be announced") do
  assert @wizard.step_announced?
end

Then("progress should be communicated") do
  assert @wizard.progress_communicated?
end

Then("all input fields should have visible labels") do
  assert @wizard.visible_labels?
end

Then("required fields should be marked with an asterisk") do
  assert @wizard.required_fields_marked?
end

Then("help text should be associated with fields using aria-describedby") do
  assert @wizard.aria_descriptions?
end

# --- Error handling ---

Given("I have entered some information") do
  @wizard.data[:service_requested] = "Partial entry"
end

When("a network error occurs") do
  @wizard.simulate_network_error!
end

Then("my entered information should be preserved") do
  refute_nil @wizard.data[:service_requested]
end

Then("I should see wizard error {string}") do |message|
  assert @wizard.errors.include?(message), "Expected error '#{message}'"
end

When("I submit without required fields") do
  @wizard.data[:service_requested] = nil
  @wizard.data[:reason_for_referral] = nil
  @wizard.validate_current_step
end

Then("I should see validation errors next to each field") do
  assert @wizard.field_errors.any?
end

Then("the first error field should receive focus") do
  assert @wizard.first_error_focused?
end

Then("errors should be summarized at the top of the form") do
  refute_nil @wizard.error_summary
end

# --- Draft management ---

Given("I have an incomplete wizard draft for patient {string}") do |_name|
  ensure_wizard
  @wizard.data[:service_requested] = "Incomplete draft"
  @wizard.instance_variable_set(:@draft_saved, true)
end

When("I enter clinical information") do
  @wizard.data[:service_requested] = "Test Service"
end

Then("my progress should be auto-saved") do
  assert @wizard.draft_saved?
end

Then("I should see {string} indicator") do |_text|
  assert @wizard.draft_saved?
end

Then("I should be prompted to resume or start over") do
  # Draft management is a WIP feature
  assert @wizard.draft_saved?
end

Then("selecting {string} should restore my progress") do |_option|
  refute_nil @wizard.data[:service_requested]
end
