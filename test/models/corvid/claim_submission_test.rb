# frozen_string_literal: true

require "test_helper"

class Corvid::ClaimSubmissionTest < ActiveSupport::TestCase
  TENANT = "tnt_cs_test"

  setup do
    Corvid::ClaimSubmission.unscoped.delete_all
  end

  test "creates with required fields" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.create!(
        patient_identifier: "pt_1",
        claim_type: "professional",
        service_date: Date.current,
        billed_amount: 500.00
      )
      assert claim.persisted?
      assert_equal "draft", claim.status
    end
  end

  test "validates patient_identifier" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(claim_type: "professional")
      refute claim.valid?
    end
  end

  test "validates claim_type" do
    with_tenant(TENANT) do
      claim = Corvid::ClaimSubmission.new(patient_identifier: "pt_1", claim_type: "bogus")
      refute claim.valid?
    end
  end

  test "pending scope" do
    with_tenant(TENANT) do
      submitted = create_claim(status: "submitted")
      paid = create_claim(status: "paid")

      assert_includes Corvid::ClaimSubmission.pending, submitted
      refute_includes Corvid::ClaimSubmission.pending, paid
    end
  end

  test "paid scope" do
    with_tenant(TENANT) do
      paid = create_claim(status: "paid")
      submitted = create_claim(status: "submitted")

      assert_includes Corvid::ClaimSubmission.paid, paid
      refute_includes Corvid::ClaimSubmission.paid, submitted
    end
  end

  test "for_patient scope" do
    with_tenant(TENANT) do
      mine = create_claim(patient_identifier: "pt_1")
      other = create_claim(patient_identifier: "pt_2")

      assert_includes Corvid::ClaimSubmission.for_patient("pt_1"), mine
      refute_includes Corvid::ClaimSubmission.for_patient("pt_1"), other
    end
  end

  test "balance_due calculates remaining" do
    with_tenant(TENANT) do
      claim = create_claim(billed_amount: 500.0, paid_amount: 300.0, adjustment_amount: 50.0)
      assert_in_delta 150.0, claim.balance_due
    end
  end

  private

  def create_claim(patient_identifier: "pt_cs", status: "submitted", **attrs)
    Corvid::ClaimSubmission.create!(
      patient_identifier: patient_identifier,
      claim_type: "professional",
      service_date: Date.current,
      status: status,
      billed_amount: attrs.delete(:billed_amount) || 100.0,
      **attrs
    )
  end
end
