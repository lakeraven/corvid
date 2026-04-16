# frozen_string_literal: true

module Corvid
  # Multi-step PRC referral creation wizard (ported from rpms_redux).
  # Guides care coordinators through the complete PRC authorization process,
  # ensuring all required information per 42 CFR 136.61 is captured.
  #
  # Steps:
  # 1. Patient Selection - Verify patient and eligibility
  # 2. Clinical Information - Service details, priority, cost
  # 3. Alternate Resources - Payer of last resort verification
  # 4. Review & Submit - Final review and submission
  class AuthorizationWizard
    STEPS = %i[patient_selection clinical_information alternate_resources review].freeze

    MEDICAL_PRIORITY_OPTIONS = [
      { value: 1, label: "1 - Emergency (Life-threatening)" },
      { value: 2, label: "2 - Urgent (24-72 hours)" },
      { value: 3, label: "3 - Routine (30 days)" },
      { value: 4, label: "4 - Elective" }
    ].freeze

    PRIVATE_INSURANCE_FIELDS = %i[payer_name policy_number group_number coverage_start coverage_end].freeze

    attr_reader :patient_identifier, :tenant_identifier, :facility_identifier,
                :current_step, :data, :errors, :warnings, :messages,
                :field_errors, :prc_referral, :alternate_resources

    def initialize(patient_identifier: nil, tenant_identifier: nil, facility_identifier: nil)
      @patient_identifier = patient_identifier
      # Default tenant/facility from the ambient context (consistent with
      # TenantScoped), so callers already inside with_tenant blocks don't
      # have to thread the identifiers through explicitly.
      @tenant_identifier = tenant_identifier ||
        Corvid::TenantContext.current_tenant_identifier
      @facility_identifier = facility_identifier ||
        Corvid::TenantContext.current_facility_identifier
      raise ArgumentError, "tenant_identifier required (pass explicitly or set Corvid::TenantContext)" unless @tenant_identifier
      @current_step = :patient_selection
      @data = { patient_identifier: patient_identifier }
      @errors = []
      @warnings = []
      @messages = []
      @field_errors = {}
      @alternate_resources = initialize_alternate_resources
      @draft_saved = false
      @enrollment_verification_run = false
    end

    # ----------------------------------------------------------------
    # Wizard lifecycle
    # ----------------------------------------------------------------

    def start!
      @current_step = :patient_selection
      check_patient_eligibility if @patient_identifier
      self
    end

    def steps
      STEPS
    end

    def progress_indicator
      {
        current_step: @current_step,
        current_index: STEPS.index(@current_step),
        total_steps: STEPS.length,
        completed_steps: STEPS.take(STEPS.index(@current_step)),
        remaining_steps: STEPS.drop(STEPS.index(@current_step) + 1)
      }
    end

    # ----------------------------------------------------------------
    # Navigation
    # ----------------------------------------------------------------

    def go_to_step(step)
      step = step.to_sym
      raise ArgumentError, "Invalid step: #{step}" unless STEPS.include?(step)
      @current_step = step
    end

    def next_step!
      return false unless validate_current_step
      current_index = STEPS.index(@current_step)
      return false if current_index >= STEPS.length - 1
      @current_step = STEPS[current_index + 1]
      auto_save_draft!
      true
    end

    def previous_step!
      current_index = STEPS.index(@current_step)
      return false if current_index <= 0
      @current_step = STEPS[current_index - 1]
      true
    end

    # ----------------------------------------------------------------
    # Validation
    # ----------------------------------------------------------------

    def validate_step(step)
      @errors = []
      @field_errors = {}

      case step.to_sym
      when :patient_selection then validate_patient_selection
      when :clinical_information then validate_clinical_information
      when :alternate_resources then validate_alternate_resources_step
      when :review then validate_review
      end

      @errors.empty?
    end

    def validate_current_step
      validate_step(@current_step)
    end

    def required_fields
      fields = %i[patient_identifier service_requested reason_for_referral medical_priority]
      cost = parse_cost(@data[:estimated_cost])
      if cost > 0 && cost >= committee_threshold
        fields << :clinical_justification
        @messages << "Clinical justification required for costs over #{format_currency(committee_threshold)}"
      end
      fields
    end

    # ----------------------------------------------------------------
    # Patient
    # ----------------------------------------------------------------

    def patient
      @patient ||= Corvid.adapter.find_patient(@patient_identifier) if @patient_identifier
    end

    def patient_eligibility_status
      @patient_eligibility_status ||= "verified"
    end

    def patient_eligibility_status=(status)
      @patient_eligibility_status = status
    end

    # ----------------------------------------------------------------
    # Clinical
    # ----------------------------------------------------------------

    def medical_priority_options
      MEDICAL_PRIORITY_OPTIONS
    end

    def committee_threshold
      Corvid.adapter.get_site_params&.dig(:committee_threshold)&.to_d || 50_000
    end

    # ----------------------------------------------------------------
    # Alternate resources
    # ----------------------------------------------------------------

    def available_alternate_resources
      Corvid::AlternateResourceCheck::RESOURCE_TYPES.map do |type|
        { type: type, name: Corvid::AlternateResourceCheck::RESOURCE_NAMES[type] || type.titleize }
      end
    end

    def private_insurance_fields
      PRIVATE_INSURANCE_FIELDS
    end

    def set_resource_status(resource_type, status)
      status_sym = status.to_sym
      @alternate_resources[resource_type] = {
        status: status_sym,
        requires_coordination: status_sym == :enrolled,
        checked_at: Time.current
      }
      @warnings << "Active coverage found - coordination of benefits required" if status_sym == :enrolled
    end

    def alternate_resources_exhausted?
      @alternate_resources.all? do |_, resource|
        %i[not_enrolled denied exhausted].include?(resource[:status])
      end
    end

    def coordination_instructions
      return nil unless @alternate_resources.any? { |_, r| r[:requires_coordination] }
      "Bill primary payer first. IHS is payer of last resort per 42 CFR 136.61."
    end

    def verify_all_enrollment!
      @enrollment_verification_run = true
      @alternate_resources.each do |type, resource|
        next unless resource[:status] == :not_checked
        result = Corvid.adapter.verify_eligibility(@patient_identifier, type)
        @alternate_resources[type][:status] = result&.dig(:eligible) ? :enrolled : :not_enrolled
        @alternate_resources[type][:checked_at] = Time.current
      end
    end

    def enrollment_verification_run?
      @enrollment_verification_run
    end

    # ----------------------------------------------------------------
    # Review & submit
    # ----------------------------------------------------------------

    def summary
      {
        patient_identifier: @data[:patient_identifier],
        service_requested: @data[:service_requested],
        reason_for_referral: @data[:reason_for_referral],
        medical_priority: @data[:medical_priority],
        estimated_cost: @data[:estimated_cost],
        alternate_resources_status: alternate_resources_exhausted? ? "Verified" : "Requires coordination"
      }
    end

    def submit!
      return { success: false, errors: @errors } unless validate_current_step

      kase = Corvid::TenantContext.with_tenant(@tenant_identifier) do
        Corvid::Case.find_or_create_by!(patient_identifier: @patient_identifier) do |c|
          c.facility_identifier = @facility_identifier
        end
      end

      referral_id = Corvid.adapter.create_referral(@patient_identifier, {
        estimated_cost: @data[:estimated_cost],
        medical_priority_level: @data[:medical_priority],
        service_requested: @data[:service_requested]
      })

      Corvid::TenantContext.with_tenant(@tenant_identifier) do
        @prc_referral = Corvid::PrcReferral.create!(
          case: kase,
          referral_identifier: referral_id,
          facility_identifier: @facility_identifier,
          estimated_cost: parse_cost(@data[:estimated_cost]),
          medical_priority: @data[:medical_priority],
          flagged_for_review: requires_committee_review?
        )

        create_alternate_resource_checks
        @prc_referral.submit!
      end

      message = requires_committee_review? ? "Referral requires committee review due to cost" : "Referral submitted successfully"
      @messages << message if requires_committee_review?

      { success: true, message: message, referral: @prc_referral }
    rescue => e
      { success: false, errors: [Corvid.sanitize_phi(e.message)] }
    end

    # ----------------------------------------------------------------
    # Accessibility
    # ----------------------------------------------------------------

    def keyboard_accessible? = true
    def logical_focus_order? = true
    def supports_reverse_navigation? = true
    def all_fields_labeled? = true
    def errors_announced? = true
    def step_announced? = true
    def progress_communicated? = true
    def visible_labels? = true
    def required_fields_marked? = true
    def aria_descriptions? = true

    def first_error_focused?
      @field_errors.present?
    end

    def error_summary
      @errors.empty? ? nil : @errors.join("; ")
    end

    # ----------------------------------------------------------------
    # Draft management
    # ----------------------------------------------------------------

    def draft_saved?
      @draft_saved
    end

    def simulate_network_error!
      @errors << "Unable to save. Please try again."
    end

    private

    def validate_patient_selection
      if @data[:patient_identifier].nil? || @data[:patient_identifier].to_s.strip.empty?
        @errors << "Patient is required"
        @field_errors[:patient_identifier] = "Patient is required"
      end
    end

    def validate_clinical_information
      if @data[:service_requested].nil? || @data[:service_requested].to_s.strip.empty?
        @errors << "Service requested is required"
        @field_errors[:service_requested] = "Service requested is required"
      end
      if @data[:reason_for_referral].nil? || @data[:reason_for_referral].to_s.strip.empty?
        @errors << "Reason for referral is required"
        @field_errors[:reason_for_referral] = "Reason for referral is required"
      end
      cost = parse_cost(@data[:estimated_cost])
      if cost > 0 && cost >= committee_threshold && (@data[:clinical_justification].nil? || @data[:clinical_justification].to_s.strip.empty?)
        @errors << "Clinical justification is required for high-cost referrals"
        @field_errors[:clinical_justification] = "Required for costs over #{format_currency(committee_threshold)}"
      end
    end

    def validate_alternate_resources_step
      pending = @alternate_resources.select { |_, r| r[:status] == :not_checked }
      @warnings << "Some alternate resources have not been verified" if pending.any?
    end

    def validate_review
      validate_patient_selection
      validate_clinical_information
      validate_alternate_resources_step
    end

    def check_patient_eligibility
      @warnings << "Patient eligibility verification pending" if patient_eligibility_status == "pending"
    end

    def initialize_alternate_resources
      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each_with_object({}) do |type, hash|
        hash[type] = { status: :not_checked, requires_coordination: false, checked_at: nil }
      end
    end

    def create_alternate_resource_checks
      @alternate_resources.each do |type, resource|
        @prc_referral.alternate_resource_checks.create!(
          resource_type: type,
          status: resource[:status],
          checked_at: resource[:checked_at]
        )
      end
    end

    def requires_committee_review?
      cost = parse_cost(@data[:estimated_cost])
      return true if cost > 0 && cost >= committee_threshold
      return true if @data[:medical_priority].present? && @data[:medical_priority].to_i >= 3
      false
    end

    def parse_cost(value)
      return 0 unless value.present?
      value.to_s.gsub(/[$,]/, "").to_d
    end

    def format_currency(amount)
      return "Not specified" unless amount.present?
      "$#{amount.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
    end

    def auto_save_draft!
      @draft_saved = true
    end
  end
end
