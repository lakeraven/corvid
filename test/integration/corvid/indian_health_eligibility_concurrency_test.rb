require "test_helper"
require "concurrent"

class Corvid::IndianHealthEligibilityConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = "tnt_example"
    @requester = "req_001"
    @agreement = "agr_001"
    Corvid::IndianHealthEligibilityInquiry.unscoped.delete_all
  end

  teardown do
    Corvid::IndianHealthEligibilityInquiry.unscoped.delete_all
    Corvid.configuration.indian_health_eligibility_ceiling = nil
    Corvid::TenantContext.reset!
  end

  class LatchAdapter
    def initialize(latch, responses)
      @latch = latch
      @responses = responses
      @calls = Concurrent::AtomicFixnum.new(0)
    end

    def indian_health_service_eligibility(person_identifier)
      call_index = @calls.increment - 1
      @latch.wait
      @responses[call_index] || {
        determination: :unknown,
        asserted_by: nil,
        determined_at: nil,
        confidence: :verified
      }
    end
  end

  test "ceiling limit 1 with 5 concurrent inquiries by one requester for 5 different people" do
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 1, period: 1.hour }

    latch = Concurrent::Event.new
    adapter = LatchAdapter.new(latch, [])
    service = Corvid::IndianHealthEligibilityService.new(adapter: adapter)

    barrier = Concurrent::CyclicBarrier.new(5)
    threads = []
    results = Concurrent::Array.new

    5.times do |i|
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          begin
            with_tenant(@tenant) do
              service.inquire(person_identifier: "pt_#{i}", requester_identifier: @requester, agreement_reference: @agreement)
            end
            results << :success
          rescue Corvid::IndianHealthEligibilityService::CeilingExceeded
            results << :exceeded
          end
        end
      end
    end

    # Wait for threads to hit the latch inside the adapter
    sleep 0.1
    latch.set

    threads.each(&:join)

    assert_equal 1, results.count(:success)
    assert_equal 4, results.count(:exceeded)

    inquiries = with_tenant(@tenant) { Corvid::IndianHealthEligibilityInquiry.where(requester_identifier: @requester).to_a }
    assert_equal 5, inquiries.size
    assert_equal 1, inquiries.count { |i| i.answer != "refused" }
    assert_equal 4, inquiries.count { |i| i.answer == "refused" }
  end

  test "2 concurrent first inquiries for the same tenant+person receive the SAME answer and exactly one non-replayed decisive row exists" do
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 10, period: 1.hour }

    latch = Concurrent::Event.new
    responses = [
      { determination: :eligible, asserted_by: "fac_demo", determined_at: Time.current.round(6), confidence: :verified },
      { determination: :not_eligible, asserted_by: "fac_demo", determined_at: Time.current.round(6), confidence: :verified }
    ]
    adapter = LatchAdapter.new(latch, responses)
    service = Corvid::IndianHealthEligibilityService.new(adapter: adapter)

    barrier = Concurrent::CyclicBarrier.new(2)
    threads = []
    results = Concurrent::Array.new

    2.times do
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          begin
            result = with_tenant(@tenant) do
              service.inquire(person_identifier: "pt_001", requester_identifier: @requester, agreement_reference: @agreement)
            end
            results << result.answer
          rescue => e
            results << e
          end
        end
      end
    end

    sleep 0.1
    latch.set

    threads.each(&:join)

    # Both should get the exact same answer (either :eligible or :not_eligible, depending on which thread won the race)
    assert_equal 2, results.size
    assert_equal results[0], results[1]
    assert_includes [ :eligible, :not_eligible ], results[0]

    # Exactly one non-replayed decisive row exists
    inquiries = with_tenant(@tenant) { Corvid::IndianHealthEligibilityInquiry.where(person_identifier: "pt_001").to_a }
    assert_equal 1, inquiries.count { |i| !i.replayed }
  end
end
