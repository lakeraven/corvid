# frozen_string_literal: true

require "test_helper"

# Repro specs for #639 / PR #688 D3: imported sent rows may record claim_identifier later.
class Corvid::ClaimSubmissionImportedSentIdentifierTest < ActiveSupport::TestCase
  TENANT = "tnt_test"

  %w[submitted accepted paid].each do |sent_status|
    test "imported #{sent_status} row without claim_identifier records identifier through update!" do
      with_tenant(TENANT) do
        claim = imported_sent_claim!(status: sent_status)
        identifier = "CLM-IMP-#{sent_status.upcase}-#{SecureRandom.hex(2)}"

        claim.update!(claim_identifier: identifier)

        claim.reload
        assert_equal sent_status, claim.status
        assert_equal identifier, claim.claim_identifier
      end
    end
  end

  test "check_status! uses recorded identifier on imported sent row" do
    with_tenant(TENANT) do
      claim = imported_sent_claim!(status: "accepted")
      identifier = "CLM-IMP-CHK-#{SecureRandom.hex(3)}"
      claim.update!(claim_identifier: identifier)

      status_calls = []
      Corvid.adapter.define_singleton_method(:check_claim_status) do |claim_id|
        status_calls << claim_id
        { status: "paid", paid_amount: 75.0 }
      end

      claim.check_status!

      assert_equal [ identifier ], status_calls
      assert_equal "paid", claim.reload.status
    end
  end

  test "never-sent draft cannot record claim_identifier through plain save" do
    with_tenant(TENANT) do
      claim = never_sent_draft_claim!
      marker = "CLM-NEVER-SENT-#{SecureRandom.hex(3)}"

      refute claim.update(claim_identifier: marker)
      assert claim.errors[:claim_identifier].present?
      claim.reload
      assert_nil claim.claim_identifier
      assert_nil claim.submitted_at
    end
  end

  test "never-sent draft cannot record submitted_at through plain save" do
    with_tenant(TENANT) do
      claim = never_sent_draft_claim!

      refute claim.update(submitted_at: Time.current)
      assert claim.errors[:submitted_at].present?
      claim.reload
      assert_nil claim.submitted_at
    end
  end

  test "never-sent draft cannot reach submitted through denied intermediate status" do
    with_tenant(TENANT) do
      claim = never_sent_draft_claim!

      claim.update!(status: "denied")
      refute claim.update(status: "submitted", claim_identifier: "CLM-BYPASS-IMPORT-SPEC")
      claim.reload
      assert_nil claim.submitted_at
      assert_nil claim.claim_identifier
      refute_equal "submitted", claim.status
    end
  end

  private

  def imported_sent_claim!(status:)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      facility_identifier: "fac_import",
      patient_identifier: "pt_import_#{SecureRandom.hex(3)}",
      referral_identifier: "REF-IMPORT-#{SecureRandom.hex(3)}",
      claim_type: "professional",
      service_date: Date.new(2027, 2, 1),
      billed_amount: 100.0,
      status: status
    )
  end

  def never_sent_draft_claim!
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT,
      patient_identifier: "pt_never_sent_#{SecureRandom.hex(3)}",
      claim_type: "professional",
      service_date: Date.current,
      billed_amount: 100.0,
      status: "draft"
    )
  end
end
