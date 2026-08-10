# frozen_string_literal: true

require "test_helper"

class Corvid::ExemptionEventTest < ActiveSupport::TestCase
  TENANT = "tnt_evt_test"

  test "creates a valid event linked to an exemption" do
    with_tenant(TENANT) do
      exemption = create_exemption
      event = Corvid::ExemptionEvent.new(
        person_identifier: "pt_evt",
        medicaid_exemption: exemption,
        event_type: "coverage_retained",
        occurred_on: Date.current
      )
      assert event.valid?, event.errors.full_messages.inspect
      assert event.save
    end
  end

  test "event may be person-level with no exemption" do
    with_tenant(TENANT) do
      event = Corvid::ExemptionEvent.new(
        person_identifier: "pt_evt",
        event_type: "erroneously_disenrolled",
        occurred_on: Date.current
      )
      assert event.valid?, event.errors.full_messages.inspect
    end
  end

  test "requires person_identifier and occurred_on" do
    with_tenant(TENANT) do
      event = Corvid::ExemptionEvent.new(event_type: "appeal_filed")
      refute event.valid?
      assert event.errors[:person_identifier].any?
      assert event.errors[:occurred_on].any?
    end
  end

  test "event_type must be a valid enum value" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) do
        Corvid::ExemptionEvent.new(event_type: "bogus")
      end
    end
  end

  test "event_type enum covers the exemption lifecycle" do
    assert_equal(
      %w[appeal_filed asserted coverage_reinstated coverage_retained
         erroneously_disenrolled expired revoked],
      Corvid::ExemptionEvent.event_types.keys.sort
    )
  end

  test "nullifying dependent leaves person-level events on exemption destroy" do
    with_tenant(TENANT) do
      exemption = create_exemption
      event = Corvid::ExemptionEvent.create!(
        person_identifier: "pt_evt",
        medicaid_exemption: exemption,
        event_type: "asserted",
        occurred_on: Date.current
      )
      exemption.destroy
      event.reload
      assert_nil event.medicaid_exemption_id
    end
  end

  private

  def create_exemption
    Corvid::MedicaidExemption.create!(
      person_identifier: "pt_evt",
      exemption_type: "work_requirement",
      status: "asserted",
      verified_at: Time.current,
      verification_source: "Corvid::Adapters::MockAdapter"
    )
  end
end
