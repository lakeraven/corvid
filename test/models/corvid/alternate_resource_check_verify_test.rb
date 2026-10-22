# frozen_string_literal: true

require "test_helper"

class Corvid::AlternateResourceCheckVerifyTest < ActiveSupport::TestCase
  TENANT = "tnt_arc_verify_test"

  UNDETERMINED_ADAPTER_RESPONSES = [
    nil,
    { eligible: nil },
    { error: "payer timeout", eligible: nil },
    { error: "unreachable" },
    { "eligible" => true, "policy_token" => "TEST-POLICY-001" },
    { "eligible" => false },
    { eligible: "false" },
    { eligible: "yes" },
    { eligible: 0 },
    { eligible: 1 },
    "unavailable"
  ].freeze

  test "verify! records enrolled when eligible is exactly true" do
    with_tenant(TENANT) do
      check = create_check(status: "not_checked")
      stub_verify_eligibility(eligible: true, policy_token: "TEST-POLICY-001")

      assert check.verify!
      check.reload

      assert_equal "enrolled", check.status
      assert_equal "TEST-POLICY-001", check.policy_token
      assert_not_nil check.checked_at
    end
  end

  test "verify! records not_enrolled when eligible is exactly false" do
    with_tenant(TENANT) do
      check = create_check(status: "not_checked")
      stub_verify_eligibility(eligible: false)

      assert check.verify!
      check.reload

      assert_equal "not_enrolled", check.status
      assert_not_nil check.checked_at
    end
  end

  test "verify! leaves fresh not_checked row unchanged for undetermined adapter responses" do
    with_tenant(TENANT) do
      UNDETERMINED_ADAPTER_RESPONSES.each do |response|
        check = create_check(status: "not_checked")
        assert_verify_leaves_unchanged(check, response)
      end
    end
  end

  test "verify! leaves prior enrolled determination unchanged for undetermined adapter responses" do
    with_tenant(TENANT) do
      prior_checked_at = 60.days.ago.change(usec: 0)

      UNDETERMINED_ADAPTER_RESPONSES.each do |response|
        check = create_check(
          status: "enrolled",
          policy_token: "TEST-POLICY-001",
          checked_at: prior_checked_at
        )
        assert_verify_leaves_unchanged(check, response)
      end
    end
  end

  test "verify! contract string-keyed eligible true never records not_enrolled" do
    with_tenant(TENANT) do
      check = create_check(status: "not_checked")
      stub_verify_eligibility("eligible" => true)

      check.verify!
      check.reload

      refute_equal "not_enrolled", check.status
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: "pt_test_001",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_referral
    Corvid::PrcReferral.create!(case: create_case, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_check(status:, policy_token: nil, checked_at: nil)
    Corvid::AlternateResourceCheck.create!(
      prc_referral: create_referral,
      resource_type: "medicare_a",
      status: status,
      policy_token: policy_token,
      checked_at: checked_at
    )
  end

  def stub_verify_eligibility(response)
    Corvid.adapter.define_singleton_method(:verify_eligibility) do |_patient_identifier, _resource_type|
      response
    end
  end

  def snapshot_check(check)
    check.reload
    {
      status: check.status,
      checked_at: check.checked_at,
      policy_token: check.policy_token
    }
  end

  def assert_verify_leaves_unchanged(check, adapter_response)
    before = snapshot_check(check)
    stub_verify_eligibility(adapter_response)

    returned = check.verify!
    check.reload

    refute returned, "verify! should return false for undetermined response #{adapter_response.inspect}"
    assert_equal before[:status], check.status
    if before[:checked_at].nil?
      assert_nil check.checked_at
    else
      assert_equal before[:checked_at], check.checked_at
    end
    if before[:policy_token].nil?
      assert_nil check.policy_token
    else
      assert_equal before[:policy_token], check.policy_token
    end
  end
end
