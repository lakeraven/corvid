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

  # -- Authorization exhaustion guard on sync_decision --------------------------

  test "sync_decision blockers name medicaid not current when stale for authorization date" do
    with_tenant("tnt_test") do
      travel_to Time.zone.parse("2025-07-01 12:00:00 UTC") do
        review = create_approved_review_in_committee_review
        referral = review.prc_referral
        exhaust_alternate_resources!(referral, date_of_service: Date.current, as_of: Time.current)
        referral.alternate_resource_checks.find_by!(resource_type: "medicaid").update!(checked_at: 31.days.ago)
        Corvid.adapter.define_singleton_method(:verify_eligibility) { |_pid, _type| raise "unreadable" }

        fake = RecordingAdapter.new
        result = Corvid::CommitteeReviewSyncService.sync_decision(review, adapter: fake)

        refute result[:success]
        assert result[:blocked]
        assert_includes result[:blockers], "medicaid: not current"
        refute_equal [ "referral: committee_review" ], result[:blockers]
        refute fake.committee_decision_synced?
      end
    end
  end

  test "sync_decision blocks approved decision when alternate resources not exhausted" do
    with_tenant(TENANT) do
      review = create_approved_review(exhaust: false)
      blockers = review.prc_referral.authorization_blockers
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_decision(review, adapter: fake)

      refute fake.update_referral_called?
      refute result[:success]
      assert result[:blocked]
      assert_equal blockers, result[:blockers]
    end
  end

  test "instance sync_decision blocks modified decision when not exhausted" do
    with_tenant(TENANT) do
      referral = create_referral
      referral.update!(status: "committee_review", medical_priority: 3, estimated_cost: 75_000)
      Corvid.adapter.add_referral(
        referral.referral_identifier,
        patient_identifier: "pt_crs",
        status: "committee_review",
        estimated_cost: 75_000,
        emergent: false,
        urgent: false,
        chs_approval_status: "P",
        service_requested: "TEST"
      )
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral,
        committee_date: Date.current,
        decision: "modified",
        approved_amount: 75_000,
        reviewer_identifier: "pr_101"
      )
      blockers = referral.authorization_blockers
      fake = RecordingAdapter.new
      service = Corvid::CommitteeReviewSyncService.new(adapter: fake)

      result = service.sync_decision(review)

      refute fake.update_referral_called?
      refute result[:success]
      assert result[:blocked]
      assert_equal blockers, result[:blockers]
    end
  end

  test "sync_decision still syncs denied decision without exhaustion check" do
    with_tenant(TENANT) do
      review = create_denied_review
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_decision(review, adapter: fake)

      assert fake.update_referral_called?
      assert result[:success]
      refute result[:blocked]
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
      referral.update!(status: "committee_review", medical_priority: 3, estimated_cost: 75_000)
      Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "committee_review", estimated_cost: 75_000, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

      exhaust_alternate_resources!(referral)

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

  test "sync_and_apply! reports referral_updated false when denied transition refused" do
    with_tenant(TENANT) do
      review = create_denied_review_in_alternate_resource_review
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_and_apply!(review, adapter: fake)

      assert fake.update_referral_called?
      assert result[:backend_synced]
      refute result[:referral_updated]
      assert_equal "alternate_resource_review", review.prc_referral.reload.status
    end
  end

  test "sync_and_apply! returns blocked with AuthorizationBlockedError blockers from apply" do
    with_tenant(TENANT) do
      review = create_approved_review_in_committee_review
      exhaust_alternate_resources!(review.prc_referral)
      review.prc_referral.return_to_eligibility_review!
      refute review.prc_referral.may_authorize?
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_and_apply!(review, adapter: fake)

      assert result[:blocked]
      assert_includes result[:blockers], "referral: eligibility_review"
      refute result[:success]
      refute result[:backend_synced]
      refute result[:referral_updated]
      refute fake.committee_decision_synced?
    end
  end

  # -- Draft exemption (#653) -------------------------------------------------

  test "committee_approval_blockers names draft when all alternate resources determined" do
    with_tenant(TENANT) do
      referral = create_referral
      exhaust_alternate_resources!(referral)

      assert_equal [ "referral: draft" ], referral.committee_approval_blockers
    end
  end

  test "sync_decision blocks approved sync for exhausted draft referral" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid.adapter.add_referral(
        referral.referral_identifier,
        patient_identifier: "pt_crs",
        status: "pending",
        estimated_cost: 50_000,
        emergent: false,
        urgent: false,
        chs_approval_status: "P",
        service_requested: "TEST"
      )
      exhaust_alternate_resources!(referral)
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral,
        committee_date: Date.current,
        decision: "approved",
        approved_amount: 50_000,
        reviewer_identifier: "pr_101"
      )
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_decision(review, adapter: fake)

      refute fake.committee_decision_synced?
      refute result[:success]
      assert result[:blocked]
      assert_equal [ "referral: draft" ], result[:blockers]
    end
  end

  test "sync_decision blocks modified sync for exhausted draft referral" do
    with_tenant(TENANT) do
      referral = create_referral
      Corvid.adapter.add_referral(
        referral.referral_identifier,
        patient_identifier: "pt_crs",
        status: "pending",
        estimated_cost: 75_000,
        emergent: false,
        urgent: false,
        chs_approval_status: "P",
        service_requested: "TEST"
      )
      exhaust_alternate_resources!(referral)
      review = Corvid::CommitteeReview.create!(
        prc_referral: referral,
        committee_date: Date.current,
        decision: "modified",
        approved_amount: 75_000,
        reviewer_identifier: "pr_101"
      )
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_decision(review, adapter: fake)

      refute fake.committee_decision_synced?
      refute result[:success]
      assert result[:blocked]
      assert_equal [ "referral: draft" ], result[:blockers]
    end
  end

  # -- Authorized referral retry (#653) ---------------------------------------

  test "committee_approval_blockers empty for authorized referral with exhaustion" do
    with_tenant(TENANT) do
      review = create_approved_review_in_committee_review
      exhaust_alternate_resources!(review.prc_referral)
      review.prc_referral.authorize!
      assert_equal "authorized", review.prc_referral.reload.status

      assert_empty review.prc_referral.committee_approval_blockers
    end
  end

  test "sync_decision retries committee approval sync for authorized referral" do
    with_tenant(TENANT) do
      review = create_approved_review_in_committee_review
      exhaust_alternate_resources!(review.prc_referral)
      review.prc_referral.authorize!
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_decision(review, adapter: fake)

      assert fake.committee_decision_synced?
      assert result[:success]
      assert_equal "AUTHORIZED", result[:backend_status]
    end
  end

  # -- authorize! refusal must not look like success (#653) -------------------

  test "sync_and_apply! does not sync committee decision when authorize! returns false" do
    with_tenant(TENANT) do
      review = create_approved_review_in_committee_review
      exhaust_alternate_resources!(review.prc_referral)
      review.prc_referral.define_singleton_method(:authorize!) { false }
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_and_apply!(review, adapter: fake)

      refute fake.committee_decision_synced?
      refute result[:success]
      assert result[:blocked]
      assert result[:blockers].present?
      refute result[:backend_synced]
      refute result[:referral_updated]
      assert_equal "committee_review", review.prc_referral.reload.status
    end
  end

  test "sync_decision returns blocked when referral cannot authorize for state" do
    with_tenant(TENANT) do
      review = create_approved_review_in_committee_review
      exhaust_alternate_resources!(review.prc_referral)
      review.prc_referral.return_to_eligibility_review!
      fake = RecordingAdapter.new

      result = Corvid::CommitteeReviewSyncService.sync_decision(review, adapter: fake)

      refute fake.update_referral_called?
      assert result[:blocked]
      assert_includes result[:blockers], "referral: eligibility_review"
      refute result[:success]
    end
  end

  # -- Conditions/attendees sync counts ---------------------------------------

  test "sync_decision includes conditions_synced count" do
    with_tenant(TENANT) do
      referral = create_referral
      referral.update!(status: "committee_review", medical_priority: 3, estimated_cost: 75_000)
      Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "committee_review", estimated_cost: 75_000, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

      conditions = [
        { "condition" => "Obtain second opinion", "required" => true },
        { "condition" => "Pre-auth from Medicare", "required" => true }
      ]
      token = Corvid.adapter.store_text(case_token: "ct_test", kind: :conditions, text: conditions)

      exhaust_alternate_resources!(referral)

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
      referral.update!(status: "committee_review", medical_priority: 3, estimated_cost: 75_000)
      Corvid.adapter.add_referral(referral.referral_identifier, patient_identifier: "pt_crs", status: "committee_review", estimated_cost: 75_000, emergent: false, urgent: false, chs_approval_status: "P", service_requested: "TEST")

      attendees = [
        { "name" => "Dr. Smith", "role" => "Chair" },
        { "name" => "Jane Johnson", "role" => "Care Manager" }
      ]
      token = Corvid.adapter.store_text(case_token: "ct_test", kind: :attendees, text: attendees)

      exhaust_alternate_resources!(referral)

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

    def committee_decision_synced?
      @calls.any? do |call|
        call.first == :update_referral && call[2].is_a?(Hash) && call[2].key?(:committee_decision)
      end
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_crs", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_approved_review(approved_amount: 50_000, exhaust: true)
    referral = create_referral
    referral.update!(status: "committee_review", medical_priority: 3, estimated_cost: approved_amount)
    # Seed the referral in the mock adapter so update_referral can find it
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
    exhaust_alternate_resources!(referral) if exhaust

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

  def create_denied_review_in_alternate_resource_review
    referral = create_referral
    referral.update!(status: "alternate_resource_review", medical_priority: 3, estimated_cost: 50_000)
    Corvid.adapter.add_referral(
      referral.referral_identifier,
      patient_identifier: "pt_crs",
      status: "alternate_resource_review",
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
