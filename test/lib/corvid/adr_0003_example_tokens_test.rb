# frozen_string_literal: true

require "test_helper"

module Corvid
  # Issue #705: ADR 0003 §4 example tokens must match OpaqueToken::FORMAT (Crockford base32).
  class Adr0003ExampleTokensTest < ActiveSupport::TestCase
    ADR_PATH = Corvid::Engine.root.join("docs/adr/0003-phi-tokenization.md")

    test "ADR 0003 section 4 table example tokens match OpaqueToken::FORMAT" do
      assert_predicate ADR_PATH, :exist?
      doc = ADR_PATH.read
      match = doc.match(/### 4\. Token format: prefixed ULIDs\n(.*?)### 5\./m)
      flunk "expected ADR 0003 section 4" if match.nil?

      example_tokens = match[1].scan(/\b[a-z]{2,4}_[0-9A-HJKMNP-TV-Z]{26}\b/).uniq
      refute_empty example_tokens, "expected prefixed ULID examples in ADR 0003 section 4"

      example_tokens.each do |token|
        assert OpaqueToken.valid?(token),
               "expected ADR 0003 section 4 example #{token.inspect} to match OpaqueToken::FORMAT"
      end
    end
  end
end
