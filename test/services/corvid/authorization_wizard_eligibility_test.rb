# frozen_string_literal: true

require "test_helper"

# Pins AuthorizationWizard#verify_all_enrollment! behavior for issue #575:
# a failed payer lookup is not a determination of no coverage.
class Corvid::AuthorizationWizardEligibilityTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  FACILITY = "fac_test"
  PATIENT = "pt_test_001"

  # MockAdapter subclass so create_referral and other wizard submit paths keep working.
  class EligibilityControllingAdapter < Corvid::Adapters::MockAdapter
    def initialize(eligibility_by_type: {}, default: nil)
      super()
      @eligibility_by_type = eligibility_by_type
      @default = default
    end

    def verify_eligibility(_patient_identifier, resource_type)
      value = @eligibility_by_type.fetch(resource_type, @default)
      value = value.call if value.is_a?(Proc)
      value
    end
  end

  setup do
    @original_adapter = Corvid.adapter
    Corvid.adapter.add_patient(
      PATIENT,
      display_name: "TEST,PATIENT 001",
      dob: Date.new(1980, 1, 1),
      sex: "F",
      ssn_last4: "0001"
    )
  end

  teardown do
    Corvid.configure { |c| c.adapter = @original_adapter }
  end

  test "eligible true sets enrolled with checked_at" do
    seed_eligible_coverage_for_all_resource_types!(PATIENT)
    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        resource = wizard.alternate_resources[type]
        assert_equal :enrolled, resource[:status], type
        refute_nil resource[:checked_at]
      end
      assert_empty eligibility_undetermined_warnings(wizard)
    end
  end

  test "eligible false sets not_enrolled with checked_at" do
    Corvid.configure do |c|
      c.adapter = EligibilityControllingAdapter.new(default: { eligible: false })
    end

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        resource = wizard.alternate_resources[type]
        assert_equal :not_enrolled, resource[:status], type
        refute_nil resource[:checked_at]
      end
      assert_empty eligibility_undetermined_warnings(wizard)
    end
  end

  test "nil lookup result leaves resource not_checked without checked_at" do
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: nil) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      assert_all_resources_undetermined!(wizard)
      assert_single_undetermined_warning!(wizard)
    end
  end

  test "eligible nil in hash leaves resource not_checked" do
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: { eligible: nil }) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      assert_all_resources_undetermined!(wizard)
      assert_single_undetermined_warning!(wizard)
    end
  end

  test "error hash leaves resource not_checked" do
    Corvid.configure do |c|
      c.adapter = EligibilityControllingAdapter.new(default: { error: "payer timeout" })
    end

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      assert_all_resources_undetermined!(wizard)
      assert_single_undetermined_warning!(wizard)
    end
  end

  test "string-keyed eligible false leaves resource not_checked" do
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: { "eligible" => false }) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      assert_all_resources_undetermined!(wizard)
      assert_single_undetermined_warning!(wizard)
    end
  end

  test "non-boolean eligible values are not treated as determinations" do
    [
      { eligible: "false" },
      { eligible: "yes" },
      { eligible: 0 },
      { eligible: 1 }
    ].each do |lookup_result|
      Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: lookup_result) }

      with_tenant(TENANT) do
        wizard = build_wizard
        wizard.verify_all_enrollment!

        assert_all_resources_undetermined!(wizard)
        assert_single_undetermined_warning!(wizard)
      end
    end
  end

  test "non-hash lookup result leaves resource not_checked" do
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: "unavailable") }

    with_tenant(TENANT) do
      wizard = build_wizard
      verification_error = nil
      begin
        wizard.verify_all_enrollment!
      rescue NoMethodError => e
        verification_error = e
      end
      assert_nil verification_error,
                 "verify_all_enrollment! should treat non-Hash results as undetermined, not raise"

      assert_all_resources_undetermined!(wizard)
      assert_single_undetermined_warning!(wizard)
    end
  end

  test "total outage does not exhaust alternate resources or mark summary Verified" do
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: nil) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      refute wizard.alternate_resources_exhausted?
      refute_equal "Verified", wizard.summary[:alternate_resources_status]
      assert_nil wizard.coordination_instructions
      assert_single_undetermined_warning!(wizard)
    end
  end

  test "second verify_all_enrollment! retries not_checked resources after source recovers" do
    adapter = EligibilityControllingAdapter.new(default: nil)
    Corvid.configure { |c| c.adapter = adapter }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!
      assert_all_resources_undetermined!(wizard)

      adapter.instance_variable_set(:@default, { eligible: false })
      wizard.verify_all_enrollment!

      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        resource = wizard.alternate_resources[type]
        assert_equal :not_enrolled, resource[:status], type
        refute_nil resource[:checked_at]
      end
      assert_empty eligibility_undetermined_warnings(wizard)
    end
  end

  test "repeated runs during an outage keep a single undetermined warning" do
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: nil) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!
      wizard.verify_all_enrollment!

      assert_single_undetermined_warning!(wizard)
    end
  end

  test "an adapter error mid-run keeps the warning for resources still undetermined" do
    types = Corvid::AlternateResourceCheck::RESOURCE_TYPES
    adapter = EligibilityControllingAdapter.new(default: nil)
    Corvid.configure { |c| c.adapter = adapter }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!
      assert_single_undetermined_warning!(wizard)

      by_type = types.each_with_index.to_h do |type, i|
        if i < 5
          [ type, { eligible: false } ]
        elsif i == 5
          [ type, -> { raise Timeout::Error, "TEST TIMEOUT" } ]
        else
          [ type, nil ]
        end
      end
      adapter.instance_variable_set(:@eligibility_by_type, by_type)
      adapter.instance_variable_set(:@default, nil)

      assert_raises(Timeout::Error) do
        wizard.verify_all_enrollment!
      end

      types.each_with_index do |type, i|
        resource = wizard.alternate_resources[type]
        if i < 5
          assert_equal :not_enrolled, resource[:status], type
          refute_nil resource[:checked_at]
        else
          assert_equal :not_checked, resource[:status], type
          assert_nil resource[:checked_at]
        end
      end

      assert_undetermined_warning_count!(wizard, types.size - 5)
    end
  end

  test "resetting an undetermined resource to not_checked keeps it in the warning count" do
    types = Corvid::AlternateResourceCheck::RESOURCE_TYPES
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: nil) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      wizard.set_resource_status(types.first, "not_checked")
      assert_undetermined_warning_count!(wizard, types.size)

      types.each { |type| wizard.set_resource_status(type, "not_checked") }
      assert_undetermined_warning_count!(wizard, types.size)
      refute wizard.alternate_resources_exhausted?
    end
  end

  test "manually recording every undetermined resource clears the undetermined warning" do
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: nil) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!
      assert_single_undetermined_warning!(wizard)

      Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
        wizard.set_resource_status(type, "not_enrolled")
      end

      assert_empty eligibility_undetermined_warnings(wizard)
      assert wizard.alternate_resources_exhausted?
    end
  end

  test "manually recording some undetermined resources updates the count" do
    types = Corvid::AlternateResourceCheck::RESOURCE_TYPES
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: nil) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!
      assert_single_undetermined_warning!(wizard)

      types.first(4).each do |type|
        wizard.set_resource_status(type, "denied")
      end

      assert_single_undetermined_warning!(wizard)
      warning = eligibility_undetermined_warnings(wizard).first
      assert_includes warning, "#{types.size - 4} alternate resource"
      refute_includes warning, "#{types.size} alternate resource"
    end
  end

  test "set_resource_status with no prior outage adds no undetermined warning" do
    with_tenant(TENANT) do
      wizard = build_wizard
      type = Corvid::AlternateResourceCheck::RESOURCE_TYPES.first
      wizard.set_resource_status(type, "not_enrolled")

      assert_empty eligibility_undetermined_warnings(wizard)
    end
  end

  test "partial recovery updates undetermined warning count" do
    types = Corvid::AlternateResourceCheck::RESOURCE_TYPES
    adapter = EligibilityControllingAdapter.new(default: nil)
    Corvid.configure { |c| c.adapter = adapter }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      assert_single_undetermined_warning!(wizard)
      assert_undetermined_warning_count!(wizard, types.size)

      by_type = types.each_with_index.to_h { |type, i| [ type, i.even? ? { eligible: false } : nil ] }
      adapter.instance_variable_set(:@eligibility_by_type, by_type)
      adapter.instance_variable_set(:@default, nil)
      wizard.verify_all_enrollment!

      types.each_with_index do |type, i|
        resource = wizard.alternate_resources[type]
        if i.even?
          assert_equal :not_enrolled, resource[:status], type
          refute_nil resource[:checked_at]
        else
          assert_equal :not_checked, resource[:status], type
          assert_nil resource[:checked_at]
        end
      end
      assert_single_undetermined_warning!(wizard)
      warning = eligibility_undetermined_warnings(wizard).first
      assert_includes warning, "#{types.size / 2} alternate resource"
      refute_includes warning, "#{types.size} alternate resource"
    end
  end

  test "mixed run records false answers and leaves nil lookups not_checked" do
    types = Corvid::AlternateResourceCheck::RESOURCE_TYPES
    by_type = types.each_with_index.to_h { |type, i| [ type, i.even? ? { eligible: false } : nil ] }
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(eligibility_by_type: by_type) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!

      types.each_with_index do |type, i|
        resource = wizard.alternate_resources[type]
        if i.even?
          assert_equal :not_enrolled, resource[:status], type
          refute_nil resource[:checked_at]
        else
          assert_equal :not_checked, resource[:status], type
          assert_nil resource[:checked_at]
        end
      end
      assert_single_undetermined_warning!(wizard)
    end
  end

  test "submit! after total outage persists not_checked and no not_enrolled rows" do
    Corvid.configure { |c| c.adapter = EligibilityControllingAdapter.new(default: nil) }

    with_tenant(TENANT) do
      wizard = build_wizard
      wizard.verify_all_enrollment!
      result = wizard.submit!

      assert result[:success], result[:errors]&.join(", ")
      referral = result[:referral]
      assert_equal Corvid::AlternateResourceCheck::RESOURCE_TYPES.size,
                   referral.alternate_resource_checks.where(status: "not_checked").count
      assert_equal 0, referral.alternate_resource_checks.where(status: "not_enrolled").count
      assert_equal 0, Corvid::AlternateResourceCheck.where(prc_referral_id: referral.id, status: "not_enrolled").count
    end
  end

  private

  def build_wizard
    wizard = Corvid::AuthorizationWizard.new(
      patient_identifier: PATIENT,
      tenant_identifier: TENANT,
      facility_identifier: FACILITY
    )
    wizard.data.merge!(
      service_requested: "TEST SERVICE",
      reason_for_referral: "TEST REASON",
      medical_priority: 3,
      estimated_cost: 5_000
    )
    wizard
  end

  def eligibility_undetermined_warnings(wizard)
    wizard.warnings.select { |w| w.include?("could not be determined") }
  end

  def assert_single_undetermined_warning!(wizard)
    matching = eligibility_undetermined_warnings(wizard)
    assert_equal 1, matching.size, "expected one undetermined warning, got: #{wizard.warnings.inspect}"
    refute_includes matching.first, PATIENT
  end

  def assert_undetermined_warning_count!(wizard, count)
    matching = eligibility_undetermined_warnings(wizard)
    assert_includes matching.first, "#{count} alternate resource"
  end

  def assert_all_resources_undetermined!(wizard)
    Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
      resource = wizard.alternate_resources[type]
      assert_equal :not_checked, resource[:status], type
      assert_nil resource[:checked_at]
    end
  end

  def seed_eligible_coverage_for_all_resource_types!(patient_identifier)
    Corvid::AlternateResourceCheck::RESOURCE_TYPES.each do |type|
      Corvid.adapter.add_coverage(patient_identifier,
                                  coverage_type: type,
                                  payer_name: "MOCK #{type.to_s.upcase} PAYER",
                                  plan_name: "Mock Plan")
    end
  end
end
