# frozen_string_literal: true

require "test_helper"
require "corvid/adapters/baseroll_adapter"

module Corvid
  class BaserollAdapterTest < ActiveSupport::TestCase
    # Stub HTTP by overriding the private get method
    class StubAdapter < Adapters::BaserollAdapter
      attr_accessor :stub_responses

      def initialize
        super(api_url: "http://baseroll.test", api_token: "test-token")
        @stub_responses = {}
      end

      private

      def get(path, _params = {})
        @stub_responses[path]
      end
    end

    setup do
      @adapter = StubAdapter.new
    end

    # =========================================================================
    # ENROLLMENT VERIFICATION
    # =========================================================================

    test "verify_tribal_enrollment returns enrolled for enrolled person" do
      @adapter.stub_responses["/api/v1/people/1"] = {
        "member_status" => "enrolled",
        "membership_number" => "YN-12345",
        "enrolled_tribe" => { "name" => "Test Tribe" },
        "born_on" => "1980-05-15"
      }

      result = @adapter.verify_tribal_enrollment("1")

      assert result[:enrolled]
      assert_equal "YN-12345", result[:membership_number]
      assert_equal "Test Tribe", result[:tribe_name]
      refute_nil result[:verified_at]
    end

    test "verify_tribal_enrollment returns not enrolled for pending person" do
      @adapter.stub_responses["/api/v1/people/2"] = {
        "member_status" => "pending",
        "enrolled_tribe" => nil
      }

      result = @adapter.verify_tribal_enrollment("2")

      refute result[:enrolled]
    end

    test "verify_tribal_enrollment returns not enrolled for denied person" do
      @adapter.stub_responses["/api/v1/people/3"] = {
        "member_status" => "denied",
        "enrolled_tribe" => nil
      }

      result = @adapter.verify_tribal_enrollment("3")

      refute result[:enrolled]
    end

    test "verify_tribal_enrollment returns not enrolled when person not found" do
      result = @adapter.verify_tribal_enrollment("999")

      refute result[:enrolled]
      assert_nil result[:membership_number]
      assert_nil result[:tribe_name]
    end

    test "verify_tribal_enrollment includes member_status" do
      @adapter.stub_responses["/api/v1/people/1"] = {
        "member_status" => "enrolled",
        "enrolled_tribe" => { "name" => "Test Tribe" }
      }

      result = @adapter.verify_tribal_enrollment("1")

      assert_equal "enrolled", result[:member_status]
    end

    # =========================================================================
    # IDENTITY VERIFICATION
    # =========================================================================

    test "verify_identity_documents detects SSN and DOB presence" do
      @adapter.stub_responses["/api/v1/people/1"] = {
        "ssn_present" => true,
        "born_on" => "1980-05-15",
        "birthplace" => "Toppenish, WA"
      }

      result = @adapter.verify_identity_documents("1")

      assert result[:ssn_present]
      assert result[:dob_present]
      assert result[:birthplace_present]
    end

    test "verify_identity_documents returns false when SSN missing" do
      @adapter.stub_responses["/api/v1/people/1"] = {
        "ssn_present" => false,
        "born_on" => "1980-05-15"
      }

      result = @adapter.verify_identity_documents("1")

      refute result[:ssn_present]
      assert result[:dob_present]
    end

    test "verify_identity_documents returns all false when person not found" do
      result = @adapter.verify_identity_documents("999")

      refute result[:ssn_present]
      refute result[:dob_present]
      refute result[:birthplace_present]
    end

    # =========================================================================
    # RESIDENCY VERIFICATION
    # =========================================================================

    test "verify_residency detects on-reservation address" do
      @adapter.stub_responses["/api/v1/people/1"] = {
        "addresses" => [
          { "on_reservation" => true, "city" => "Toppenish", "service_area" => "Yakama Reservation" }
        ]
      }

      result = @adapter.verify_residency("1")

      assert result[:on_reservation]
      assert_equal "Toppenish", result[:address]
      assert_equal "Yakama Reservation", result[:service_area]
    end

    test "verify_residency returns false when off-reservation" do
      @adapter.stub_responses["/api/v1/people/1"] = {
        "addresses" => [
          { "on_reservation" => false, "city" => "Seattle" }
        ]
      }

      result = @adapter.verify_residency("1")

      refute result[:on_reservation]
    end

    test "verify_residency returns false when no addresses" do
      @adapter.stub_responses["/api/v1/people/1"] = {
        "addresses" => []
      }

      result = @adapter.verify_residency("1")

      refute result[:on_reservation]
    end

    test "verify_residency returns false when person not found" do
      result = @adapter.verify_residency("999")

      refute result[:on_reservation]
    end

    # =========================================================================
    # PATIENT LOOKUP
    # =========================================================================

    test "find_patient returns name and DOB" do
      @adapter.stub_responses["/api/v1/people/1"] = {
        "full_name" => "Jane Doe",
        "born_on" => "1980-05-15"
      }

      result = @adapter.find_patient("1")

      assert_equal "1", result[:identifier]
      assert_equal "Jane Doe", result[:name]
      assert_equal "1980-05-15", result[:dob]
    end

    test "find_patient returns nil when not found" do
      result = @adapter.find_patient("999")

      assert_nil result
    end

    # =========================================================================
    # CACHING
    # =========================================================================

    test "person data is cached across verification calls" do
      call_count = 0
      @adapter.define_singleton_method(:get) do |path, _params = {}|
        call_count += 1
        { "member_status" => "enrolled", "enrolled_tribe" => { "name" => "T" }, "ssn_present" => true, "born_on" => "1980-01-01", "addresses" => [] }
      end

      @adapter.verify_tribal_enrollment("1")
      @adapter.verify_identity_documents("1")
      @adapter.verify_residency("1")

      assert_equal 1, call_count, "Expected only 1 API call (cached)"
    end
  end
end
