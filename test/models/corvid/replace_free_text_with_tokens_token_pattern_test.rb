# frozen_string_literal: true

require "test_helper"
require_relative "../../support/opaque_token_check_mutants"

module Corvid
  class ReplaceFreeTextWithTokensTokenPatternTest < ActiveSupport::TestCase
    setup do
      @migration_path = tokens_migration_path
      require @migration_path unless defined?(ReplaceFreeTextWithTokens)
      @pattern = ReplaceFreeTextWithTokens::TOKEN_PATTERN
      @ruby_pattern = OpaqueTokenCheckMutants.postgres_pattern_to_ruby(@pattern)
      @clm_pattern = ReplaceFreeTextWithTokens::CLM_CLAIM_PATTERN
      @clm_ruby_pattern = OpaqueTokenCheckMutants.postgres_pattern_to_ruby(@clm_pattern)
    end

    test "migration TOKEN_PATTERN rejects CHECK-regex mutant opaque token anchors" do
      OpaqueTokenCheckMutants.malformed_opaque_token_anchors(prefix: "rv").each do |bad|
        refute_match @ruby_pattern, bad,
                     "expected migration pattern to reject #{bad.inspect}"
      end
    end

    test "migration TOKEN_PATTERN rejects the same anchors as OpaqueToken::FORMAT" do
      OpaqueTokenCheckMutants.malformed_opaque_token_anchors(prefix: "at").each do |bad|
        refute OpaqueToken.valid?(bad), "fixture #{bad.inspect} should be invalid for OpaqueToken"
        refute_match @ruby_pattern, bad,
                     "expected migration TOKEN_PATTERN to reject #{bad.inspect}"
      end
    end

    test "migration CLM_CLAIM_PATTERN rejects malformed CLM claim anchor mutants" do
      OpaqueTokenCheckMutants.malformed_clm_claim_identifiers.each do |bad|
        refute_match @clm_ruby_pattern, bad,
                     "expected migration CLM_CLAIM_PATTERN to reject #{bad.inspect}"
      end
    end

    test "FmapDetermination CLM_FORMAT rejects malformed CLM claim anchor mutants" do
      OpaqueTokenCheckMutants.malformed_clm_claim_identifiers.each do |bad|
        refute FmapDetermination::CLM_FORMAT.match?(bad),
               "expected CLM_FORMAT to reject #{bad.inspect}"
      end
    end

    private

    def tokens_migration_path
      paths = Dir[
        Rails.root.join("db/migrate/*_replace_free_text_with_tokens.rb").to_s,
        Corvid::Engine.root.join("db/migrate/*_replace_free_text_with_tokens.rb").to_s
      ]
      flunk "expected migration file matching *_replace_free_text_with_tokens.rb" if paths.empty?

      paths.first
    end
  end
end
