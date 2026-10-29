# frozen_string_literal: true

require "test_helper"

module Corvid
  # Issue #705: ADR 0003 example tokens must match engine token formats.
  class Adr0003ExampleTokensTest < ActiveSupport::TestCase
    ADR_PATH = Corvid::Engine.root.join("docs/adr/0003-phi-tokenization.md")
    PREFIX_BODY_PATTERN = /\b[a-z]{2,4}_[0-9A-Za-z]+\b/
    CLM_BODY_PATTERN = /\bCLM_[0-9A-Za-z]+\b/

    # Full prefixed ULID examples in §4 (prefix-only mentions in a future "Engine identifiers"
    # section do not match PREFIX_BODY_PATTERN). Bump when new complete examples are added.
    EXPECTED_PREFIXED_ULID_EXAMPLE_COUNT = 11

    ENGINE_IDENTIFIERS_SECTION_PATTERN = /^#+ Engine identifiers\s*\n(.*?)(?=^#+ |\z)/m

    test "ADR 0003 prefixed ULID and CLM examples match engine token formats" do
      assert_predicate ADR_PATH, :exist?
      assert_adr_prefixed_examples_match_engine!(ADR_PATH.read)
    end

    test "ADR 0003 prefixed example validation fails when a scratch copy shortens an example body to 25 characters" do
      doc = ADR_PATH.read
      full = "pt_01HK8B7Z9XCQVG3F8N5K0R4MWB"
      _prefix, body = full.split("_", 2)
      shortened = "pt_#{body[0, 25]}"
      assert_equal 25, shortened.split("_", 2).last.length

      scratch = doc.sub(full, shortened)
      assert_includes prefixed_ulid_examples_in(scratch), shortened

      error = assert_raises(Minitest::Assertion) do
        assert_adr_prefixed_examples_match_engine!(scratch)
      end
      assert_match(/OpaqueToken::FORMAT/, error.message)
    end

    test "ADR 0003 prefixed example validation fails when a scratch copy lowercases an example body" do
      doc = ADR_PATH.read
      full = "pt_01HK8B7Z9XCQVG3F8N5K0R4MWB"
      lowercased = full.sub("01HK8B7Z9XCQVG3F8N5K0R4MWB", "01hk8b7z9xcqvg3f8n5k0r4mwb")

      scratch = doc.sub(full, lowercased)
      assert_includes prefixed_ulid_examples_in(scratch), lowercased

      error = assert_raises(Minitest::Assertion) do
        assert_adr_prefixed_examples_match_engine!(scratch)
      end
      assert_match(/OpaqueToken::FORMAT/, error.message)
    end

    test "ADR 0003 documents Engine identifiers with required prefixes" do
      assert_predicate ADR_PATH, :exist?
      doc = ADR_PATH.read
      section = doc.match(ENGINE_IDENTIFIERS_SECTION_PATTERN)
      flunk "expected ADR 0003 Engine identifiers section" if section.nil?

      body = section[1]
      assert_includes body, "CLM_"
      assert_includes body, "PAY_"
      assert_includes body, "pt_"
      assert_includes body, "pr_"
      assert_includes body, "rf_"
      assert_includes body, "PHI"
      refute_includes body, "lowercase"
    end

    test "ADR 0003 includes exactly one CLM example matching CLM_FORMAT" do
      assert_predicate ADR_PATH, :exist?
      clm_examples = ADR_PATH.read.scan(CLM_BODY_PATTERN).uniq
      assert_equal 1, clm_examples.size,
                   "expected exactly one full CLM_ example in ADR 0003"
      assert FmapDetermination::CLM_FORMAT.match?(clm_examples.sole),
             "expected ADR 0003 CLM example #{clm_examples.sole.inspect} to match CLM_FORMAT"
    end

    private

    def prefixed_ulid_examples_in(doc)
      doc.scan(PREFIX_BODY_PATTERN).uniq.select do |token|
        _prefix, body = token.split("_", 2)
        body.length >= 16
      end
    end

    def assert_adr_prefixed_examples_match_engine!(doc)
      prefixed_examples = prefixed_ulid_examples_in(doc)

      assert_equal EXPECTED_PREFIXED_ULID_EXAMPLE_COUNT, prefixed_examples.size,
                   "prefixed ULID examples with body length >= 16 in ADR 0003"

      prefixed_examples.each do |token|
        assert OpaqueToken.valid?(token),
               "expected ADR 0003 example #{token.inspect} to match OpaqueToken::FORMAT"
      end

      clm_examples = doc.scan(CLM_BODY_PATTERN).uniq
      assert_equal 1, clm_examples.size,
                   "expected exactly one full CLM_ example in ADR 0003"
      clm_examples.each do |token|
        assert FmapDetermination::CLM_FORMAT.match?(token),
               "expected ADR 0003 CLM example #{token.inspect} to match CLM_FORMAT"
      end
    end
  end
end
