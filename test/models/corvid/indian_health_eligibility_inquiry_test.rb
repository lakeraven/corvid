require "test_helper"

class Corvid::IndianHealthEligibilityInquiryTest < ActiveSupport::TestCase
  setup { Corvid::TenantContext.current_tenant_identifier = "tnt_example" }
  teardown { Corvid::TenantContext.reset! }

  test "schema matches exactly the required columns" do
    expected_columns = %w[
      id
      tenant_identifier
      requester_identifier
      agreement_reference
      person_identifier
      answer
      data_source
      asserted_at
      message_id
      replayed
      created_at
      updated_at
    ].sort

    actual_columns = Corvid::IndianHealthEligibilityInquiry.column_names.sort
    assert_equal expected_columns, actual_columns, "Table columns do not match the exact expected schema"
  end

  test "answer column has a database CHECK constraint for allowed values" do
    # Assuming the table exists and Corvid::IndianHealthEligibilityInquiry model is there,
    # we need to ensure the DB rejects an invalid answer.
    inquiry = Corvid::IndianHealthEligibilityInquiry.create!(
      tenant_identifier: "tnt_example",
      requester_identifier: "req_001",
      agreement_reference: "agr_001",
      person_identifier: "pt_001",
      answer: "eligible",
      message_id: SecureRandom.uuid,
      replayed: false
    )

    error = assert_raises(ActiveRecord::StatementInvalid) do
      # update_column skips ActiveRecord validations and hits the DB directly
      inquiry.update_column(:answer, "invalid_value")
    end
    assert_match(/check constraint/i, error.message, "Expected a CHECK constraint violation for invalid answer")
  end

  test "validates answer against allowed values" do
    inquiry = Corvid::IndianHealthEligibilityInquiry.new(
      tenant_identifier: "tnt_example",
      requester_identifier: "req_001",
      agreement_reference: "agr_001",
      person_identifier: "pt_001",
      answer: "invalid_value",
      message_id: SecureRandom.uuid,
      replayed: false
    )

    assert_not inquiry.valid?
    assert_includes inquiry.errors[:answer], "is not included in the list"

    %w[eligible not_eligible unknown unavailable refused].each do |valid_answer|
      inquiry.answer = valid_answer
      assert inquiry.valid?, "Expected '#{valid_answer}' to be a valid answer"
    end
  end
end
