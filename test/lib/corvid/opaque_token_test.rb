# frozen_string_literal: true

require "test_helper"

module Corvid
  class OpaqueTokenTest < ActiveSupport::TestCase
    ADR_EXAMPLE = "pt_01HK8B7Z9XCQVG3F8N5K0R4MWB"

    test "ADR 0003 prefixed ULID examples are valid opaque tokens" do
      assert_opaque_token_implemented!
      assert OpaqueToken.valid?(ADR_EXAMPLE)
      assert OpaqueToken.valid?("at_01HK8B7Z9XCQVG3F8N5K0R4MWC")
      assert OpaqueToken.valid?("cl_01HK8B7Z9XCQVG3F8N5K0R4MWD")
    end

    test "legacy and human-readable strings are not opaque tokens" do
      assert_opaque_token_implemented!
      refute OpaqueToken.valid?("tok_example_aian")
      refute OpaqueToken.valid?("attestation:tok_example_aian")
      refute OpaqueToken.valid?("clm_example_1")
      refute OpaqueToken.valid?("Jane Doe")
      refute OpaqueToken.valid?("123-45-6789")
    end

    test "blank and non-string values are not opaque tokens" do
      assert_opaque_token_implemented!
      refute OpaqueToken.valid?("")
      refute OpaqueToken.valid?(nil)
      refute OpaqueToken.valid?(:pt_01HK8B7Z9XCQVG3F8N5K0R4MWB)
    end

    test "M7 trailing newline after a valid token is not an opaque token" do
      assert_opaque_token_implemented!
      refute OpaqueToken.valid?("#{ADR_EXAMPLE}\n")
    end

    test "M8 a prefix or leading space before a valid token is not an opaque token" do
      assert_opaque_token_implemented!
      refute OpaqueToken.valid?("1#{ADR_EXAMPLE}")
      refute OpaqueToken.valid?("-#{ADR_EXAMPLE}")
      refute OpaqueToken.valid?(" #{ADR_EXAMPLE}")
    end

    test "a ULID containing Crockford-forbidden letters is not an opaque token" do
      assert_opaque_token_implemented!
      refute OpaqueToken.valid?("pt_01HK8B7Z9XCQVG3F8N5K0R4MWI")
      refute OpaqueToken.valid?("pt_01HK8B7Z9XCQVG3F8N5K0R4MWL")
      refute OpaqueToken.valid?("pt_01HK8B7Z9XCQVG3F8N5K0R4MWO")
      refute OpaqueToken.valid?("pt_01HK8B7Z9XCQVG3F8N5K0R4MWU")
    end

    private

    def assert_opaque_token_implemented!
      assert defined?(OpaqueToken), "Corvid::OpaqueToken must be implemented"
    end
  end
end
