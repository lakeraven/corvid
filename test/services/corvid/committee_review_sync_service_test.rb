# frozen_string_literal: true

require "test_helper"

class Corvid::CommitteeReviewSyncServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_crs_test"

  test "finalized review can apply to referral" do
    with_tenant(TENANT) do
      referral = create_referral
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral, committee_date: Date.current,
        decision: "approved", approved_amount: 50_000
      )

      assert review.finalized?
    end
  end

  test "pending review is not finalized" do
    with_tenant(TENANT) do
      referral = create_referral
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral, committee_date: Date.current
      )

      refute review.finalized?
    end
  end

  # -- Sync approved decisions ------------------------------------------------

  test "sync_decision syncs approved decision" do
    with_tenant(TENANT) do
      review = create_approved_review
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal "AUTHORIZED", result[:backend_status]
    end
  end

  test "sync_decision includes approval amount" do
    with_tenant(TENANT) do
      review = create_approved_review(approved_amount: 75_000)
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal 75_000, result[:synced_amount]
    end
  end

  test "sync_decision includes committee date" do
    with_tenant(TENANT) do
      review = create_approved_review
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal Date.current, result[:committee_date]
    end
  end

  # -- Sync denied decisions --------------------------------------------------

  test "sync_decision syncs denied decision" do
    with_tenant(TENANT) do
      review = create_denied_review(rationale_text: "Not medically necessary")
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal "DENIED", result[:backend_status]
    end
  end

  test "sync_decision includes denial reason" do
    with_tenant(TENANT) do
      review = create_denied_review(rationale_text: "Service not covered")
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal "Service not covered", result[:denial_reason]
    end
  end

  # -- Sync deferred decisions ------------------------------------------------

  test "sync_decision syncs deferred decision" do
    with_tenant(TENANT) do
      review = create_deferred_review(rationale_text: "Awaiting additional documentation")
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal "PENDING", result[:backend_status]
    end
  end

  test "sync_decision includes defer reason" do
    with_tenant(TENANT) do
      review = create_deferred_review(rationale_text: "Need Medicare enrollment")
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal "Need Medicare enrollment", result[:defer_reason]
    end
  end

  # -- Sync modified decisions ------------------------------------------------

  test "sync_decision syncs modified approval" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "pending", estimated_cost: 75_000, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

      review = Corvid::CommitteeReview.create!(
        prc_referral: referral, committee_date: Date.current,
        decision: "modified", approved_amount: 75_000,
        reviewer_identifier: "pr_101"
      )
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal "AUTHORIZED", result[:backend_status]
      assert_equal 75_000, result[:synced_amount]
    end
  end

  # -- Pending decisions ------------------------------------------------------

  test "sync_decision returns error for pending decision" do
    with_tenant(TENANT) do
      review = Corvid::CommitteeReview.create!(
        prc_referral: create_referral, committee_date: Date.current
      )
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      refute result[:success]
      assert_equal "Cannot sync pending decision", result[:error]
    end
  end

  # -- Error handling ---------------------------------------------------------

  test "sync_decision handles blank referral identifier" do
    with_tenant(TENANT) do
      referral = create_referral
      # Bypass NOT NULL by stubbing the method on the referral
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral, committee_date: Date.current,
        decision: "approved", approved_amount: 75_000,
        reviewer_identifier: "pr_101"
      )
      # Simulate blank identifier via method override on the association
      referral.define_singleton_method(:referral_identifier) { nil }
      review.define_singleton_method(:prc_referral) { referral }

      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      refute result[:success]
      assert_equal "Missing referral IEN", result[:error]
    end
  end

  # -- Sync status tracking ---------------------------------------------------

  test "sync_decision returns sync timestamp on success" do
    with_tenant(TENANT) do
      review = create_approved_review
      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert result[:synced_at].present?
      assert result[:synced_at].is_a?(Time)
    end
  end

  # -- sync_and_apply! --------------------------------------------------------

  test "sync_and_apply! syncs and applies to referral when alternate resources exhausted" do
    with_tenant(TENANT) do
      review = create_approved_review_in_committee_review
      exhaust_alternate_resources!(review.prc_referral)

      result = Corvid::CommitteeReviewSyncService.sync_and_apply!(review)

      assert result[:success]
      assert result[:backend_synced]
      assert result[:referral_updated]
      assert_equal "authorized", review.prc_referral.reload.status
    end
  end

  test "sync_and_apply! does not sync EHR when authorization blocked by alternate resources" do
    with_tenant(TENANT) do
      review = create_approved_review_in_committee_review
      exhaust_alternate_resources!(review.prc_referral)
      review.prc_referral.alternate_resource_checks.find_by!(resource_type: "medicare_a").update!(status: "enrolled")
      blockers = review.prc_referral.authorization_blockers
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_and_apply!(review, adapter: fake)

      refute fake.update_referral_called?
      refute result[:success]
      refute result[:backend_synced]
      refute result[:referral_updated]
      assert result[:blocked]
      assert_equal blockers, result[:blockers]
      assert_equal "committee_review", review.prc_referral.reload.status
    end
  end

  test "sync_and_apply! still syncs denied decisions without exhaustion check" do
    with_tenant(TENANT) do
      review = create_denied_review_in_committee_review
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_and_apply!(review, adapter: fake)

      assert fake.update_referral_called?
      assert result[:backend_synced]
      assert result[:referral_updated]
      assert_equal "denied", review.prc_referral.reload.status
    end
  end

  # -- Conditions/attendees sync counts ---------------------------------------

  test "sync_decision includes conditions_synced count" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "pending", estimated_cost: 75_000, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

      conditions = [
        { "condition" => "Obtain second opinion", "required" => true },
        { "condition" => "Pre-auth from Medicare", "required" => true }
      ]
      token = Corvid.adapter.store_text(case_token: "ct_test", kind: :conditions, text: conditions)

      review = Corvid::CommitteeReview.create!(
        prc_referral: referral, committee_date: Date.current,
        decision: "approved", approved_amount: 75_000,
        reviewer_identifier: "pr_101", conditions_token: token
      )

      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal 2, result[:conditions_synced]
    end
  end

  test "sync_decision includes attendees_synced count" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "pending", estimated_cost: 75_000, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

      attendees = [
        { "name" => "Dr. Smith", "role" => "Chair" },
        { "name" => "Jane Johnson", "role" => "Care Manager" }
      ]
      token = Corvid.adapter.store_text(case_token: "ct_test", kind: :attendees, text: attendees)

      review = Corvid::CommitteeReview.create!(
        prc_referral: referral, committee_date: Date.current,
        decision: "approved", approved_amount: 75_000,
        reviewer_identifier: "pr_101", attendees_token: token
      )

      result = Corvid::CommitteeReviewSyncService.sync_decision(review)

      assert result[:success]
      assert_equal 2, result[:attendees_synced]
    end
  end

  # Records adapter calls for sync_and_apply! authorization-guard specs.
  class RecordingAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def update_referral(identifier, params)
      @calls << [ :update_referral, identifier, params ]
      true
    end

    def fetch_text(token)
      @calls << [ :fetch_text, token ]
      "denial reason"
    end

    def update_referral_called?
      @calls.any? { |call| call.first == :update_referral }
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_crs", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_approved_review(approved_amount: 50_000)
    referral = create_referral
    # Seed the referral in the mock adapter so update_referral can find it
    Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "pending", estimated_cost: approved_amount, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

    Corvid::CommitteeReview.create!(
      prc_referral: referral, committee_date: Date.current,
      decision: "approved", approved_amount: approved_amount,
      reviewer_identifier: "pr_101"
    )
  end

  def create_approved_review_in_committee_review(approved_amount: 50_000)
    referral = create_referral
    referral.update!(status: "committee_review", medical_priority: 3, estimated_cost: approved_amount)
    Corvid.adapter.add_referral(
      referral.referral_identifier,
      patient_identifier: "pt_crs",
      status: "committee_review",
      estimated_cost: approved_amount,
      emergent: false,
      urgent: false,
      chs_approval_status: "P",
      service_requested: "TEST"
    )

    Corvid::CommitteeReview.create!(
      prc_referral: referral,
      committee_date: Date.current,
      decision: "approved",
      approved_amount: approved_amount,
      reviewer_identifier: "pr_101"
    )
  end

  def create_denied_review_in_committee_review
    referral = create_referral
    referral.update!(status: "committee_review", medical_priority: 3, estimated_cost: 50_000)
    Corvid.adapter.add_referral(
      referral.referral_identifier,
      patient_identifier: "pt_crs",
      status: "committee_review",
      estimated_cost: 50_000,
      emergent: false,
      urgent: false,
      chs_approval_status: "P",
      service_requested: "TEST"
    )

    rationale_token = Corvid.adapter.store_text(case_token: "ct_test", kind: :rationale, text: "Not medically necessary")

    Corvid::CommitteeReview.create!(
      prc_referral: referral,
      committee_date: Date.current,
      decision: "denied",
      rationale_token: rationale_token,
      appeal_instructions_token: "ai_test",
      reviewer_identifier: "pr_101"
    )
  end

  def create_denied_review(rationale_text: "Test denial")
    referral = create_referral
    Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "pending", estimated_cost: 50_000, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

    rationale_token = Corvid.adapter.store_text(case_token: "ct_test", kind: :rationale, text: rationale_text)

    Corvid::CommitteeReview.create!(
      prc_referral: referral, committee_date: Date.current,
      decision: "denied", rationale_token: rationale_token,
      appeal_instructions_token: "ai_test",
      reviewer_identifier: "pr_101"
    )
  end

  def create_deferred_review(rationale_text: "Test deferral")
    referral = create_referral
    Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "pending", estimated_cost: 50_000, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

    rationale_token = Corvid.adapter.store_text(case_token: "ct_test", kind: :rationale, text: rationale_text)

    Corvid::CommitteeReview.create!(
      prc_referral: referral, committee_date: Date.current,
      decision: "deferred", rationale_token: rationale_token,
      reviewer_identifier: "pr_101"
    )
  end
end
