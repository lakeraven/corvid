# frozen_string_literal: true

require "test_helper"

# Exercises the assert contract: verified AI/AN status → exemption(s) +
# :asserted event, all fail-closed (no self-report, no fabricated positive).
class Corvid::MedicaidExemptionServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_svc_test"

  # Stub adapter that returns a fixed verify_ai_an_status payload verbatim, to
  # exercise untrusted/malformed responses the MockAdapter can't emit (it always
  # stamps verified_at and a real confidence). Named (not anonymous) so
  # adapter.class.name yields a real verification_source.
  class CannedAiAnAdapter
    def initialize(payload)
      @payload = payload
    end

    def verify_ai_an_status(_person_identifier)
      @payload
    end
  end

  setup do
    Corvid::TenantContext.current_tenant_identifier = TENANT
    @adapter = Corvid.adapter
  end

  # -- Verified positive -----------------------------------------------------

  test "asserts both HR-1 exemptions from verified AI/AN status" do
    @adapter.add_ai_an_status("pt_v", ai_an: true, ihs_beneficiary: true,
                              basis: "ai_an_ihs_beneficiary", confidence: :verified)

    result = Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_v", asserted_by_identifier: "usr_1"
    )

    assert result.asserted?
    assert_equal :asserted, result.reason
    assert_equal 2, result.exemption_ids.size

    types = Corvid::MedicaidExemption.for_person("pt_v").active.pluck(:exemption_type).sort
    assert_equal %w[six_month_redetermination work_requirement], types
  end

  test "records an :asserted event per exemption with provenance on the row" do
    @adapter.add_ai_an_status("pt_v", ai_an: true, confidence: :verified)

    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_v", exemption_types: [ "work_requirement" ],
      asserted_by_identifier: "usr_1"
    )

    exemption = Corvid::MedicaidExemption.for_person("pt_v").active.first
    assert_equal "Corvid::Adapters::MockAdapter", exemption.verification_source
    assert_equal "verified", exemption.verification_confidence
    refute_nil exemption.verification_snapshot_hash
    refute_nil exemption.verified_at

    events = Corvid::ExemptionEvent.for_person("pt_v").of_type("asserted")
    assert_equal 1, events.count
  end

  # -- Re-assert refreshes, does not duplicate -------------------------------

  test "re-asserting refreshes the same exemption row" do
    @adapter.add_ai_an_status("pt_v", ai_an: true, confidence: :verified)

    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_v", exemption_types: [ "work_requirement" ])
    assert_no_difference "Corvid::MedicaidExemption.count" do
      Corvid::MedicaidExemptionService.assert(person_identifier: "pt_v", exemption_types: [ "work_requirement" ])
    end
  end

  # -- Fail-closed: unavailable source ---------------------------------------

  test "does not assert when the verification source is unavailable" do
    @adapter.add_ai_an_status("pt_u", ai_an: true, confidence: :unavailable)

    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_u")

    refute result.asserted?
    assert_equal :verification_unavailable, result.reason
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_u").count
  end

  # -- Fail-closed: not AI/AN ------------------------------------------------

  test "does not assert when the person is not AI/AN" do
    @adapter.add_ai_an_status("pt_n", ai_an: false, ihs_beneficiary: false, confidence: :verified)

    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_n")

    refute result.asserted?
    assert_equal :not_ai_an, result.reason
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_n").count
  end

  test "unknown person (no status record) is a verified negative, not asserted" do
    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_unknown")
    refute result.asserted?
    assert_equal :not_ai_an, result.reason
  end

  # -- Fail-closed: untrusted / malformed verification response --------------
  # (ALLOW-LIST) assert only from an accepted confidence + genuine verified_at.
  # The MockAdapter always stamps verified_at and a real confidence, so these
  # use a stub adapter that emits the raw payload.

  test "does not assert when confidence is nil" do
    use_canned_adapter(ai_an: true, ihs_beneficiary: true, confidence: nil, verified_at: Time.current)

    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_nilc")

    refute result.asserted?
    assert_equal :verification_unavailable, result.reason
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_nilc").count
    assert_equal 0, Corvid::ExemptionEvent.for_person("pt_nilc").count
  end

  test "does not assert on an unknown confidence level" do
    use_canned_adapter(ai_an: true, ihs_beneficiary: true, confidence: :probably, verified_at: Time.current)

    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_unk")

    refute result.asserted?
    assert_equal :verification_unavailable, result.reason
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_unk").count
    assert_equal 0, Corvid::ExemptionEvent.for_person("pt_unk").count
  end

  test "does not assert when verified_at is missing" do
    use_canned_adapter(ai_an: true, ihs_beneficiary: true, confidence: :verified, verified_at: nil)

    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_nov")

    refute result.asserted?
    assert_equal :verification_unavailable, result.reason
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_nov").count
    assert_equal 0, Corvid::ExemptionEvent.for_person("pt_nov").count
  end

  test "does not assert from a stale response (allow-list boundary)" do
    use_canned_adapter(ai_an: true, basis: "ai_an_ihs_beneficiary",
                       confidence: :stale, verified_at: Time.current)

    result = Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_stale", exemption_types: [ "work_requirement" ]
    )

    refute result.asserted?
    assert_equal :verification_unavailable, result.reason
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_stale").count
    assert_equal 0, Corvid::ExemptionEvent.for_person("pt_stale").count
  end

  # -- Deterministic snapshot hash -------------------------------------------

  test "identical verified status yields an identical snapshot hash" do
    @adapter.add_ai_an_status("pt_h", ai_an: true, ihs_beneficiary: true,
                              basis: "ai_an_ihs_beneficiary", confidence: :verified)

    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_h", exemption_types: [ "work_requirement" ])
    first = Corvid::MedicaidExemption.for_person("pt_h").active.first.verification_snapshot_hash
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_h", exemption_types: [ "work_requirement" ])
    second = Corvid::MedicaidExemption.for_person("pt_h").active.first.verification_snapshot_hash

    assert_equal first, second
  end

  # -- Honest seam: production adapter fails closed ---------------------------

  test "assert propagates NotImplementedError from a production adapter and asserts nothing" do
    Corvid.configure { |c| c.adapter = Corvid::Adapters::Base.new }

    assert_raises(NotImplementedError) do
      Corvid::MedicaidExemptionService.assert(person_identifier: "pt_prod")
    end

    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_prod").count
    assert_equal 0, Corvid::ExemptionEvent.for_person("pt_prod").count
  end

  # -- Concurrency: unique-index race is a benign duplicate ------------------

  test "assert treats a concurrent unique-violation as a benign duplicate" do
    @adapter.add_ai_an_status("pt_race", ai_an: true, ihs_beneficiary: true,
                              basis: "ai_an_ihs_beneficiary", confidence: :verified)

    # The row a concurrent assert already committed for the same subject/type;
    # our insert will lose the race against the partial unique index.
    winner = Corvid::MedicaidExemption.create!(
      tenant_identifier: TENANT, person_identifier: "pt_race",
      exemption_type: "work_requirement", status: "asserted",
      basis: "ai_an_ihs_beneficiary", as_of_date: Date.current,
      effective_date: Date.current, verified_at: Time.current,
      verification_source: "Corvid::Adapters::MockAdapter",
      verification_confidence: "verified"
    )

    result = with_first_save_raising(ActiveRecord::RecordNotUnique) do
      Corvid::MedicaidExemptionService.assert(
        person_identifier: "pt_race", exemption_types: [ "work_requirement" ]
      )
    end

    assert result.asserted?
    assert_equal :asserted, result.reason
    assert_equal [ winner.id ], result.exemption_ids
    # Recovered to the winning row — exactly one exemption, one asserted event.
    assert_equal 1, Corvid::MedicaidExemption.for_person("pt_race").count
    assert_equal 1, Corvid::ExemptionEvent.for_person("pt_race").of_type("asserted").count
  end

  # -- Empty exemption list is not a success ---------------------------------

  test "assert with an empty exemption_types list is rejected, not a false success" do
    @adapter.add_ai_an_status("pt_e", ai_an: true, confidence: :verified)

    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_e", exemption_types: [])

    refute result.asserted?
    assert_equal :no_exemption_types, result.reason
    assert_empty result.exemption_ids
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_e").count
  end

  # -- Outcome events --------------------------------------------------------

  test "record_outcome rejects an exemption from another tenant" do
    other = nil
    with_tenant("tnt_other") do
      @adapter.add_ai_an_status("pt_x", ai_an: true, confidence: :verified)
      Corvid::MedicaidExemptionService.assert(person_identifier: "pt_x", exemption_types: [ "work_requirement" ])
      other = Corvid::MedicaidExemption.for_person("pt_x").active.first
    end

    assert_raises(ArgumentError) do
      Corvid::MedicaidExemptionService.record_outcome(
        person_identifier: "pt_x", event_type: "coverage_retained", exemption: other
      )
    end
    assert_equal 0, Corvid::ExemptionEvent.for_person("pt_x").where(tenant_identifier: TENANT).count
  end

  test "record_outcome rejects an exemption belonging to a different person" do
    @adapter.add_ai_an_status("pt_a", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_a", exemption_types: [ "work_requirement" ])
    exemption_a = Corvid::MedicaidExemption.for_person("pt_a").active.first

    assert_raises(ArgumentError) do
      Corvid::MedicaidExemptionService.record_outcome(
        person_identifier: "pt_b", event_type: "coverage_retained", exemption: exemption_a
      )
    end
  end

  test "record_outcome writes a life-outcome event" do
    @adapter.add_ai_an_status("pt_o", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_o", exemption_types: [ "work_requirement" ])
    exemption = Corvid::MedicaidExemption.for_person("pt_o").active.first

    event = Corvid::MedicaidExemptionService.record_outcome(
      person_identifier: "pt_o",
      event_type: "erroneously_disenrolled",
      exemption: exemption,
      recorded_by_identifier: "usr_2"
    )

    assert event.persisted?
    assert event.event_erroneously_disenrolled?
    assert_equal "work_requirement", event.exemption_type
  end

  # -- Basis is evidenced, never defaulted -----------------------------------

  test "a source that evidences AI/AN only does not record the IHS-beneficiary basis" do
    @adapter.add_ai_an_status("pt_basis", ai_an: true, ihs_beneficiary: false,
                              basis: nil, confidence: :verified)

    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_basis", exemption_types: [ "work_requirement" ]
    )

    exemption = Corvid::MedicaidExemption.for_person("pt_basis").active.first
    assert_equal "ai_an", exemption.basis
    refute_equal "ai_an_ihs_beneficiary", exemption.basis

    # The attestation the state receives carries the evidenced subcategory.
    attestation = Corvid::ExemptionAttestationService.generate(person_identifier: "pt_basis")
    assert_equal "ai_an", attestation[:exemptions].first[:basis]
  end

  test "the IHS-beneficiary basis is recorded when the source evidences it" do
    @adapter.add_ai_an_status("pt_ihs", ai_an: true, ihs_beneficiary: true,
                              basis: nil, confidence: :verified)

    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_ihs", exemption_types: [ "work_requirement" ]
    )

    assert_equal "ai_an_ihs_beneficiary",
                 Corvid::MedicaidExemption.for_person("pt_ihs").active.first.basis
  end

  test "a basis the source states is carried through verbatim" do
    @adapter.add_ai_an_status("pt_stated", ai_an: true, basis: "ai_an_urban_indian",
                              confidence: :verified)

    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_stated", exemption_types: [ "work_requirement" ]
    )

    assert_equal "ai_an_urban_indian",
                 Corvid::MedicaidExemption.for_person("pt_stated").active.first.basis
  end

  # -- A verified negative revokes a standing assertion ----------------------

  test "a verified not-AI/AN result revokes the standing assertion with an audit event" do
    @adapter.add_ai_an_status("pt_rev", ai_an: true, ihs_beneficiary: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_rev")
    assert_equal 2, Corvid::MedicaidExemption.for_person("pt_rev").active.count

    # The source now verifies the person is NOT AI/AN.
    @adapter.add_ai_an_status("pt_rev", ai_an: false, ihs_beneficiary: false, confidence: :verified)
    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_rev")

    refute result.asserted?
    assert_equal :not_ai_an, result.reason
    assert_equal 2, result.revoked_exemption_ids.size

    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_rev").active.count
    exemptions = Corvid::MedicaidExemption.for_person("pt_rev")
    assert exemptions.all? { |e| e.status_revoked? }
    refute exemptions.any? { |e| e.in_effect? }
    assert_equal 2, Corvid::ExemptionEvent.for_person("pt_rev").of_type("revoked").count
  end

  test "a revoked exemption no longer attests or lands on the at-risk worklist" do
    @adapter.add_ai_an_status("pt_rev2", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_rev2", exemption_types: [ "work_requirement" ]
    )

    @adapter.add_ai_an_status("pt_rev2", ai_an: false, ihs_beneficiary: false, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_rev2", exemption_types: [ "work_requirement" ]
    )

    assert_raises(ArgumentError) do
      Corvid::ExemptionAttestationService.generate(person_identifier: "pt_rev2")
    end

    at_risk = Corvid::ExemptionWorklistService.at_risk([
      { person_identifier: "pt_rev2", requirement_type: "work_requirement", source: "state_271" }
    ])
    assert_empty at_risk
  end

  test "an unavailable source does not revoke a standing assertion" do
    @adapter.add_ai_an_status("pt_keep", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_keep", exemption_types: [ "work_requirement" ]
    )

    @adapter.add_ai_an_status("pt_keep", ai_an: true, confidence: :unavailable)
    result = Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_keep", exemption_types: [ "work_requirement" ]
    )

    assert_equal :verification_unavailable, result.reason
    assert_empty result.revoked_exemption_ids
    assert_equal 1, Corvid::MedicaidExemption.for_person("pt_keep").active.count
  end

  # -- Terminal outcomes move the derived status -----------------------------

  test "record_outcome :revoked transitions the exemption out of asserted" do
    @adapter.add_ai_an_status("pt_out", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_out", exemption_types: [ "work_requirement" ]
    )
    exemption = Corvid::MedicaidExemption.for_person("pt_out").active.first

    Corvid::MedicaidExemptionService.record_outcome(
      person_identifier: "pt_out", event_type: "revoked", exemption: exemption
    )

    exemption.reload
    assert exemption.status_revoked?
    refute exemption.in_effect?
    assert_raises(ArgumentError) do
      Corvid::ExemptionAttestationService.generate(person_identifier: "pt_out")
    end
  end

  test "record_outcome :expired transitions every standing assertion when no exemption is named" do
    @adapter.add_ai_an_status("pt_exp", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_exp")

    Corvid::MedicaidExemptionService.record_outcome(
      person_identifier: "pt_exp", event_type: "expired"
    )

    exemptions = Corvid::MedicaidExemption.for_person("pt_exp")
    assert_equal 2, exemptions.count
    assert exemptions.all? { |e| e.status_expired? }
  end

  test "record_outcome :expired scoped to one type leaves the other standing" do
    @adapter.add_ai_an_status("pt_exp2", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_exp2")

    Corvid::MedicaidExemptionService.record_outcome(
      person_identifier: "pt_exp2", event_type: "expired", exemption_type: "work_requirement"
    )

    statuses = Corvid::MedicaidExemption.for_person("pt_exp2").to_h { |e| [ e.exemption_type, e.status ] }
    assert_equal "expired", statuses["work_requirement"]
    assert_equal "asserted", statuses["six_month_redetermination"]
  end

  test "a non-terminal outcome leaves the exemption asserted" do
    @adapter.add_ai_an_status("pt_ret", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_ret", exemption_types: [ "work_requirement" ]
    )
    exemption = Corvid::MedicaidExemption.for_person("pt_ret").active.first

    Corvid::MedicaidExemptionService.record_outcome(
      person_identifier: "pt_ret", event_type: "coverage_retained", exemption: exemption
    )

    assert exemption.reload.status_asserted?
  end

  private

  def use_canned_adapter(payload)
    Corvid.configure { |c| c.adapter = CannedAiAnAdapter.new(payload) }
  end

  # Make MedicaidExemption#save! raise the given error exactly once (the
  # unique-index race), then fall through to the real save! — so the rescue
  # path's update! still persists. Restored afterward.
  def with_first_save_raising(error_class)
    klass = Corvid::MedicaidExemption
    original = klass.instance_method(:save!)
    fired = false
    klass.send(:define_method, :save!) do |*args, **kwargs|
      unless fired
        fired = true
        raise error_class, "duplicate key value violates unique constraint"
      end
      original.bind(self).call(*args, **kwargs)
    end
    yield
  ensure
    klass.send(:define_method, :save!, original)
  end
end
