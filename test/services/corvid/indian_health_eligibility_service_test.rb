require "test_helper"

class Corvid::IndianHealthEligibilityServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = "tnt_example"
    @adapter = Corvid::Adapters::MockAdapter.new
    @service = Corvid::IndianHealthEligibilityService.new(adapter: @adapter)
    @requester = "req_001"
    @agreement = "agr_001"

    # Reset ceiling configuration
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 10, period: 1.hour }
  end

  teardown do
    Corvid.configuration.indian_health_eligibility_ceiling = nil
    Corvid::TenantContext.reset!
  end

  # Counts adapter calls, so replay can be shown not to consult the source.
  class CountingAdapter
    attr_reader :calls

    def initialize(inner)
      @inner = inner
      @calls = 0
    end

    def indian_health_service_eligibility(patient_identifier)
      @calls += 1
      @inner.indian_health_service_eligibility(patient_identifier)
    end
  end

  test "base adapter raises NotImplementedError for indian_health_service_eligibility" do
    base_adapter = Corvid::Adapters::Base.new
    assert_raises(NotImplementedError) do
      base_adapter.indian_health_service_eligibility("pt_001")
    end
  end

  test "adapter seam does not respond to removed evidence methods" do
    assert_not @adapter.respond_to?(:verify_tribal_descent)
    assert_not @adapter.respond_to?(:verify_alaska_native_corporation_shareholder)
    assert_not @adapter.respond_to?(:list_itu_encounters)

    base_adapter = Corvid::Adapters::Base.new
    assert_not base_adapter.respond_to?(:verify_tribal_descent)
    assert_not base_adapter.respond_to?(:verify_alaska_native_corporation_shareholder)
    assert_not base_adapter.respond_to?(:list_itu_encounters)
  end

  test "passes through the provider's answer and provenance" do
    determined_at = Time.current.round(6)
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: determined_at,
      confidence: :verified
    })

    result = nil
    with_tenant(@tenant) do
      result = @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
    end

    assert_equal :eligible, result.answer
    assert_equal "fac_demo", result.data_source
    assert_equal determined_at, result.asserted_at
    assert result.message_id.is_a?(String)
    assert_not result.replayed?
  end

  test "unseeded mock adapter returns unknown and verified" do
    result = nil
    with_tenant(@tenant) do
      result = @service.inquire(person_identifier: "pt_unseeded", requester_identifier: @requester, agreement_reference: @agreement)
    end

    assert_equal :unknown, result.answer
    assert_nil result.data_source
    assert_nil result.asserted_at
  end

  test "one bit only: extra adapter keys are ignored and not logged" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :not_eligible,
      asserted_by: "fac_demo",
      determined_at: Time.current.round(6),
      confidence: :verified,
      tribe_code: "TRIBE_X9",
      enrolled: "ENR_Z3",
      basis: "BASIS_Q7",
      relationship: "self"
    })

    with_tenant(@tenant) do
      @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
    end

    inquiry = with_tenant(@tenant) { Corvid::IndianHealthEligibilityInquiry.last }
    row_values = inquiry.attributes.values.map(&:to_s).join
    assert_not_includes row_values, "TRIBE_X9"
    assert_not_includes row_values, "ENR_Z3"
    assert_not_includes row_values, "BASIS_Q7"
  end

  test "source unavailable: when confidence is unavailable" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :unknown,
      asserted_by: nil,
      determined_at: nil,
      confidence: :unavailable
    })

    with_tenant(@tenant) do
      assert_raises(Corvid::IndianHealthEligibilityService::SourceUnavailable) do
        @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      end
      inquiry = Corvid::IndianHealthEligibilityInquiry.last
      assert_equal "unavailable", inquiry.answer
    end
  end

  test "source unavailable: when adapter raises StandardError" do
    adapter = Object.new
    def adapter.indian_health_service_eligibility(*)
      raise StandardError, "API timeout"
    end
    service = Corvid::IndianHealthEligibilityService.new(adapter: adapter)

    with_tenant(@tenant) do
      assert_raises(Corvid::IndianHealthEligibilityService::SourceUnavailable) do
        service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      end
      inquiry = Corvid::IndianHealthEligibilityInquiry.last
      assert_equal "unavailable", inquiry.answer
    end
  end

  test "source unavailable: when adapter raises NotImplementedError" do
    adapter = Corvid::Adapters::Base.new
    service = Corvid::IndianHealthEligibilityService.new(adapter: adapter)

    with_tenant(@tenant) do
      assert_raises(Corvid::IndianHealthEligibilityService::SourceUnavailable) do
        service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      end
      inquiry = Corvid::IndianHealthEligibilityInquiry.last
      assert_equal "unavailable", inquiry.answer
    end
  end

  test "source unavailable: decisive answer missing provenance" do
    [
      { determination: :eligible, asserted_by: "", determined_at: Time.current, confidence: :verified },
      { determination: :eligible, asserted_by: nil, determined_at: Time.current, confidence: :verified },
      { determination: :eligible, asserted_by: 123, determined_at: Time.current, confidence: :verified },
      { determination: :eligible, asserted_by: "fac_demo", determined_at: Date.today, confidence: :verified },
      { determination: :eligible, asserted_by: "fac_demo", determined_at: nil, confidence: :verified },
      { determination: :eligible, asserted_by: "fac_demo", determined_at: Time.current, confidence: :unverified },
      { determination: :eligible, asserted_by: "fac_demo", determined_at: Time.current, confidence: nil },
      { determination: :eligible, asserted_by: { provider: "fac_demo", basis: "x" }, determined_at: Time.current, confidence: :verified }
    ].each_with_index do |bad_response, i|
      @adapter.add_service_eligibility("pt_bad_#{i}", bad_response)

      with_tenant(@tenant) do
        assert_raises(Corvid::IndianHealthEligibilityService::SourceUnavailable) do
          @service.inquire(person_identifier: "pt_bad_#{i}", requester_identifier: @requester, agreement_reference: @agreement)
        end
        inquiry = Corvid::IndianHealthEligibilityInquiry.last
        assert_equal "unavailable", inquiry.answer
      end
    end
  end

  test "asymmetric immutability: eligible is frozen per tenant and person, adapter not called again" do
    original_time = (Time.current - 1.day).round(6)
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: original_time,
      confidence: :verified
    })

    first_result = nil
    with_tenant(@tenant) do
      first_result = @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
    end
    assert_equal :eligible, first_result.answer
    assert_not first_result.replayed?

    # Adapter's answer changes
    @adapter.add_service_eligibility("pt_001", {
      determination: :not_eligible,
      asserted_by: "fac_other",
      determined_at: Time.current.round(6),
      confidence: :verified
    })

    second_result = nil
    with_tenant(@tenant) do
      second_result = @service.inquire(person_identifier: "pt_001", requester_identifier: "req_002", agreement_reference: "agr_002")
    end

    # Should be frozen to original
    assert_equal :eligible, second_result.answer
    assert_equal "fac_demo", second_result.data_source
    assert_equal original_time, second_result.asserted_at
    assert second_result.replayed?
  end

  test "asymmetric immutability: not_eligible is frozen exactly like eligible" do
    original_time = (Time.current - 1.day).round(6)
    @adapter.add_service_eligibility("pt_001", {
      determination: :not_eligible,
      asserted_by: "fac_demo",
      determined_at: original_time,
      confidence: :verified
    })

    counting = CountingAdapter.new(@adapter)
    service = Corvid::IndianHealthEligibilityService.new(adapter: counting)

    with_tenant(@tenant) do
      first_result = service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      assert_equal :not_eligible, first_result.answer
      assert_not first_result.replayed?

      # Adapter's answer changes
      @adapter.add_service_eligibility("pt_001", {
        determination: :eligible,
        asserted_by: "fac_other",
        determined_at: Time.current.round(6),
        confidence: :verified
      })

      second_result = service.inquire(person_identifier: "pt_001", requester_identifier: "req_002", agreement_reference: "agr_002")
      assert_equal :not_eligible, second_result.answer
      assert_equal "fac_demo", second_result.data_source
      assert_equal original_time, second_result.asserted_at
      assert second_result.replayed?
      assert_equal 1, counting.calls
    end
  end

  test "asymmetric immutability: tenant isolation" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: Time.current.round(6),
      confidence: :verified
    })

    with_tenant("tnt_1") do
      @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
    end

    # Adapter's answer changes
    @adapter.add_service_eligibility("pt_001", {
      determination: :not_eligible,
      asserted_by: "fac_other",
      determined_at: Time.current.round(6),
      confidence: :verified
    })

    second_result = nil
    with_tenant("tnt_2") do
      second_result = @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
    end

    # Tenant 2 gets the fresh answer, not replayed from Tenant 1
    assert_equal :not_eligible, second_result.answer
    assert_not second_result.replayed?
  end

  test "asymmetric immutability: unknown is NOT frozen and adapter is called again" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :unknown,
      asserted_by: nil,
      determined_at: nil,
      confidence: :verified
    })

    with_tenant(@tenant) do
      first_result = @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      assert_equal :unknown, first_result.answer
      assert_not first_result.replayed?
    end

    # Adapter's answer changes
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: Time.current.round(6),
      confidence: :verified
    })

    with_tenant(@tenant) do
      second_result = @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      assert_equal :eligible, second_result.answer
      assert_not second_result.replayed?
    end
  end

  test "asymmetric immutability: unavailable is NOT frozen and adapter is called again" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :unknown,
      asserted_by: nil,
      determined_at: nil,
      confidence: :unavailable
    })

    counting = CountingAdapter.new(@adapter)
    service = Corvid::IndianHealthEligibilityService.new(adapter: counting)

    with_tenant(@tenant) do
      assert_raises(Corvid::IndianHealthEligibilityService::SourceUnavailable) do
        service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      end
      assert_equal 1, counting.calls

      @adapter.add_service_eligibility("pt_001", {
        determination: :eligible,
        asserted_by: "fac_demo",
        determined_at: Time.current.round(6),
        confidence: :verified
      })

      second_result = service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      assert_equal :eligible, second_result.answer
      assert_equal 2, counting.calls
    end
  end

  test "asymmetric immutability: refused is NOT frozen and adapter is called again" do
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 1, period: 1.hour }

    counting = CountingAdapter.new(@adapter)
    service = Corvid::IndianHealthEligibilityService.new(adapter: counting)

    with_tenant(@tenant) do
      service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      assert_raises(Corvid::IndianHealthEligibilityService::CeilingExceeded) do
        service.inquire(person_identifier: "pt_002", requester_identifier: @requester, agreement_reference: @agreement)
      end

      # Now pt_002 has a refused row. Let's query it with a different requester.
      result = service.inquire(person_identifier: "pt_002", requester_identifier: "req_002", agreement_reference: @agreement)
      assert_equal :unknown, result.answer
      assert_equal 2, counting.calls
    end
  end

  test "volume ceiling: nil ceiling raises CeilingNotConfigured and fails closed" do
    Corvid.configuration.indian_health_eligibility_ceiling = nil

    with_tenant(@tenant) do
      assert_raises(Corvid::IndianHealthEligibilityService::CeilingNotConfigured) do
        @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      end
    end

    assert_equal 0, Corvid::IndianHealthEligibilityInquiry.unscoped.count
  end

  test "volume ceiling: invalid ceiling config raises CeilingNotConfigured" do
    [
      { limit: "10", period: 1.hour },
      { limit: -1, period: 1.hour },
      { limit: 10, period: 3600 },
      { limit: 10, period: "1 hour" },
      { limit: 10, period: 0.seconds },
      { limit: 10, period: -1.hour }
    ].each do |bad_config|
      Corvid.configuration.indian_health_eligibility_ceiling = bad_config
      with_tenant(@tenant) do
        assert_raises(Corvid::IndianHealthEligibilityService::CeilingNotConfigured) do
          @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
        end
      end
    end
  end

  test "volume ceiling: comes before replay, and a replay consumes quota" do
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 1, period: 1.hour }

    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: Time.current.round(6),
      confidence: :verified
    })

    with_tenant(@tenant) do
      # Requester A inquires person P (eligible, logged)
      first_result = @service.inquire(person_identifier: "pt_001", requester_identifier: "req_A", agreement_reference: @agreement)
      assert_equal :eligible, first_result.answer

      # Second inquiry by A for P raises CeilingExceeded, logs refused
      assert_raises(Corvid::IndianHealthEligibilityService::CeilingExceeded) do
        @service.inquire(person_identifier: "pt_001", requester_identifier: "req_A", agreement_reference: @agreement)
      end

      inquiry = Corvid::IndianHealthEligibilityInquiry.where(requester_identifier: "req_A").last
      assert_equal "refused", inquiry.answer

      # Different requester B (own quota) gets the replay
      b_result = @service.inquire(person_identifier: "pt_001", requester_identifier: "req_B", agreement_reference: @agreement)
      assert_equal :eligible, b_result.answer
      assert b_result.replayed?

      # B's replay consumed B's quota
      assert_raises(Corvid::IndianHealthEligibilityService::CeilingExceeded) do
        @service.inquire(person_identifier: "pt_001", requester_identifier: "req_B", agreement_reference: @agreement)
      end
    end
  end

  test "volume ceiling: exceeds limit within period raises CeilingExceeded, logs refused, and adapter not called" do
    limit = 2
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: limit, period: 1.hour }

    counting = CountingAdapter.new(@adapter)
    service = Corvid::IndianHealthEligibilityService.new(adapter: counting)

    # Unseeded adapter returns unknown
    with_tenant(@tenant) do
      limit.times do |i|
        service.inquire(person_identifier: "pt_#{i}", requester_identifier: @requester, agreement_reference: @agreement)
      end

      # Next inquiry should be refused without asking the provider
      assert_raises(Corvid::IndianHealthEligibilityService::CeilingExceeded) do
        service.inquire(person_identifier: "pt_blocked", requester_identifier: @requester, agreement_reference: @agreement)
      end
      assert_equal limit, counting.calls

      inquiry = Corvid::IndianHealthEligibilityInquiry.last
      assert_equal "refused", inquiry.answer
      assert_equal "pt_blocked", inquiry.person_identifier
    end
  end

  test "volume ceiling: limits are per requester" do
    limit = 1
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: limit, period: 1.hour }

    with_tenant(@tenant) do
      @service.inquire(person_identifier: "pt_001", requester_identifier: "req_001", agreement_reference: @agreement)

      assert_raises(Corvid::IndianHealthEligibilityService::CeilingExceeded) do
        @service.inquire(person_identifier: "pt_002", requester_identifier: "req_001", agreement_reference: @agreement)
      end

      # req_002 is unaffected
      result = @service.inquire(person_identifier: "pt_003", requester_identifier: "req_002", agreement_reference: @agreement)
      assert_equal :unknown, result.answer
    end
  end

  test "volume ceiling: outside period does not count" do
    limit = 1
    period = 1.hour
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: limit, period: period }

    with_tenant(@tenant) do
      travel_to(2.hours.ago) do
        @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      end

      # Currently this requester has 0 inquiries in the last hour
      result = @service.inquire(person_identifier: "pt_002", requester_identifier: @requester, agreement_reference: @agreement)
      assert_equal :unknown, result.answer
    end
  end

  test "volume ceiling: refused rows do not count toward limit" do
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 1, period: 1.hour }

    with_tenant(@tenant) do
      3.times do |i|
        Corvid::IndianHealthEligibilityInquiry.create!(
          tenant_identifier: @tenant,
          requester_identifier: @requester, agreement_reference: @agreement,
          person_identifier: "pt_refused_#{i}", answer: "refused",
          message_id: SecureRandom.uuid, replayed: false
        )
      end

      result = @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      assert_equal :unknown, result.answer
    end
  end

  test "asymmetric immutability: a replayed answer does not consult the adapter" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :not_eligible, asserted_by: "fac_demo",
      determined_at: (Time.current - 1.day).round(6), confidence: :verified
    })
    counting = CountingAdapter.new(@adapter)
    service = Corvid::IndianHealthEligibilityService.new(adapter: counting)

    with_tenant(@tenant) do
      service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      replay = service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      assert_equal :not_eligible, replay.answer
      assert replay.replayed?
    end

    assert_equal 1, counting.calls
  end

  test "query log rows are tenant-scoped" do
    with_tenant("tnt_1") do
      @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
    end

    with_tenant("tnt_2") do
      assert_equal 0, Corvid::IndianHealthEligibilityInquiry.count
    end
    with_tenant("tnt_1") do
      assert_equal 1, Corvid::IndianHealthEligibilityInquiry.count
    end
    assert_raises(Corvid::MissingTenantContextError) { Corvid::IndianHealthEligibilityInquiry.count }
  end

  test "required inputs: raises ArgumentError and nothing logged" do
    with_tenant(@tenant) do
      assert_raises(ArgumentError) do
        @service.inquire(person_identifier: "", requester_identifier: @requester, agreement_reference: @agreement)
      end
      assert_raises(ArgumentError) do
        @service.inquire(person_identifier: nil, requester_identifier: @requester, agreement_reference: @agreement)
      end
      assert_raises(ArgumentError) do
        @service.inquire(person_identifier: "pt_001", requester_identifier: " ", agreement_reference: @agreement)
      end
      assert_raises(ArgumentError) do
        @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: nil)
      end
    end
    assert_equal 0, Corvid::IndianHealthEligibilityInquiry.unscoped.count
  end

  test "query log writes exactly one row per inquiry with correct attributes" do
    determined_at = Time.current.round(6)
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: determined_at,
      confidence: :verified
    })

    result = nil
    with_tenant(@tenant) do
      assert_difference "Corvid::IndianHealthEligibilityInquiry.count", 1 do
        result = @service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
      end
    end

    inquiry = with_tenant(@tenant) { Corvid::IndianHealthEligibilityInquiry.last }
    assert_equal @tenant, inquiry.tenant_identifier
    assert_equal @requester, inquiry.requester_identifier
    assert_equal @agreement, inquiry.agreement_reference
    assert_equal "pt_001", inquiry.person_identifier
    assert_equal "eligible", inquiry.answer
    assert_equal "fac_demo", inquiry.data_source
    assert_equal determined_at.round(6), inquiry.asserted_at
    assert_equal result.message_id, inquiry.message_id
    assert_equal false, inquiry.replayed
  end

  test "source unavailable: an unrecognised determination or a non-Hash response" do
    [ { determination: :maybe, asserted_by: "fac_demo", determined_at: Time.current, confidence: :verified },
      nil,
      "eligible" ].each_with_index do |response, i|
      adapter = Object.new
      adapter.define_singleton_method(:indian_health_service_eligibility) { |_| response }
      service = Corvid::IndianHealthEligibilityService.new(adapter: adapter)

      with_tenant(@tenant) do
        assert_raises(Corvid::IndianHealthEligibilityService::SourceUnavailable) do
          service.inquire(person_identifier: "pt_shape_#{i}", requester_identifier: @requester, agreement_reference: @agreement)
        end
        assert_equal "unavailable", Corvid::IndianHealthEligibilityInquiry.where(person_identifier: "pt_shape_#{i}").last.answer
      end
    end
  end

  test "source unavailable: a database-backed adapter whose query fails still logs unavailable" do
    adapter = Object.new
    adapter.define_singleton_method(:indian_health_service_eligibility) do |_|
      ActiveRecord::Base.connection.select_value("SELECT * FROM corvid_no_such_table")
    end
    service = Corvid::IndianHealthEligibilityService.new(adapter: adapter)

    with_tenant(@tenant) do
      error = assert_raises(Corvid::IndianHealthEligibilityService::SourceUnavailable) do
        service.inquire(person_identifier: "pt_db", requester_identifier: @requester, agreement_reference: @agreement)
      end
      row = Corvid::IndianHealthEligibilityInquiry.find_by(message_id: error.message_id)
      assert_equal "unavailable", row.answer
    end
  end
end
