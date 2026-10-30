# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "corvid/rcm"

# Typed 277 claim status (#740): category mapping from STC01-1, the ClaimStatus
# value object, and standalone loading of the mapping table.
class Corvid::Rcm::ClaimStatusTest < Minitest::Test
  VALID_CATEGORIES = %i[
    acknowledged pending finalized_paid finalized_denied rejected not_found undetermined
  ].freeze

  INVALID_CLAIM_IDENTIFIER_MESSAGE = "claim_identifier must be a non-blank String"

  CATEGORY_CODE_EXPECTATIONS = {
    "A0" => :acknowledged,
    "A1" => :acknowledged,
    "A2" => :acknowledged,
    "A5" => :acknowledged,
    "A3" => :rejected,
    "A6" => :rejected,
    "A7" => :rejected,
    "A8" => :rejected,
    "A4" => :not_found,
    "P0" => :pending,
    "P1" => :pending,
    "P2" => :pending,
    "P3" => :pending,
    "P4" => :pending,
    "P5" => :pending,
    "F1" => :finalized_paid,
    "F2" => :finalized_denied,
    "F0" => :undetermined,
    "F3" => :undetermined,
    "F3F" => :undetermined,
    "F3N" => :undetermined,
    "F4" => :undetermined,
    "E0" => :undetermined,
    "E1" => :undetermined,
    "E2" => :undetermined,
    "E3" => :undetermined,
    "E4" => :undetermined
  }.freeze

  UNMAPPED_CATEGORY_CODES = [ "Z9", "A9", "F5", "", nil, "f1", " F1" ].freeze

  EXPECTED_MEMBERS = %i[
    claim_identifier payer_control_number category category_code status_code
    paid_amount paid_date as_of raw_reference
  ].freeze

  FIXED_AS_OF = Time.utc(2026, 9, 1, 12, 0, 0)

  def test_claim_status_exposes_the_issue_members_in_order
    assert_equal EXPECTED_MEMBERS, Corvid::Rcm::ClaimStatus.members
  end

  # -- category_for (277 STC01-1) ------------------------------------------

  CATEGORY_CODE_EXPECTATIONS.each do |code, expected|
    define_method("test_category_for_maps_#{code}_to_#{expected}") do
      assert_equal expected, Corvid::Rcm::ClaimStatus.category_for(code)
    end
  end

  UNMAPPED_CATEGORY_CODES.each do |code|
    label = code.nil? ? "nil" : code.empty? ? "empty_string" : code.gsub(/\W/, "_")

    define_method("test_category_for_treats_#{label}_as_undetermined") do
      assert_equal :undetermined, Corvid::Rcm::ClaimStatus.category_for(code)
    end
  end

  def test_an_unmapped_category_code_is_never_paid_or_denied
    UNMAPPED_CATEGORY_CODES.each do |code|
      category = Corvid::Rcm::ClaimStatus.category_for(code)

      refute_equal :finalized_paid, category, "unmapped #{code.inspect} must not read as paid"
      refute_equal :finalized_denied, category, "unmapped #{code.inspect} must not read as denied"
    end
  end

  def test_rejected_category_codes_are_never_finalized_denied
    %w[A3 A6 A7 A8].each do |code|
      refute_equal :finalized_denied, Corvid::Rcm::ClaimStatus.category_for(code)
    end
  end

  # -- YAML mapping table ----------------------------------------------------

  def test_the_category_mapping_table_lives_on_disk_and_uses_only_known_categories
    path = File.expand_path("../../../lib/corvid/rcm/data/claim_status_categories.yml", __dir__)

    assert File.file?(path), "expected claim_status_categories.yml beside other RCM data tables"

    table = YAML.safe_load_file(path)
    allowed = VALID_CATEGORIES.map(&:to_s)

    table.each do |code, category|
      assert_includes allowed, category.to_s,
                      "#{code.inspect} maps to #{category.inspect}, not one of #{allowed.join(', ')}"
    end
  end

  def test_category_for_loads_without_rails_or_active_record
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "corvid/rcm"
      abort("ActiveRecord was loaded") if defined?(ActiveRecord::Base)
      abort("Rails was loaded") if defined?(Rails)
      category = Corvid::Rcm::ClaimStatus.category_for("F1")
      abort("expected finalized_paid, got \#{category.inspect}") unless category == :finalized_paid
    RUBY

    assert system(RbConfig.ruby, "-I", lib, "-e", script),
           "ClaimStatus.category_for must work in a plain Ruby process"
  end

  # -- construction validation ---------------------------------------------

  def test_raw_reference_defaults_to_nil
    status = valid_status(category: :pending, category_code: "P1")

    assert_nil status.raw_reference
  end

  def test_unknown_category_symbols_are_rejected
    error = assert_raises(ArgumentError) do
      valid_status(category: :paid, category_code: "F1")
    end

    assert_match(/unknown claim status category/i, error.message)
  end

  def test_blank_claim_identifiers_are_rejected_without_echoing_the_value
    [ nil, "", "   " ].each do |bad|
      error = assert_raises(ArgumentError) { valid_status(claim_identifier: bad) }

      assert_equal INVALID_CLAIM_IDENTIFIER_MESSAGE, error.message
      refute_includes error.message, bad.to_s if bad.is_a?(String) && !bad.strip.empty?
    end
  end

  def test_paid_amount_must_be_bigdecimal_or_nil
    assert_raises(ArgumentError) do
      valid_status(category: :finalized_paid, category_code: "F1", paid_amount: 125.40)
    end
    assert_raises(ArgumentError) do
      valid_status(category: :finalized_paid, category_code: "F1", paid_amount: 125)
    end
  end

  def test_paid_amount_is_only_allowed_on_finalized_paid
    assert_raises(ArgumentError) do
      valid_status(category: :pending, category_code: "P1", paid_amount: BigDecimal("1.00"))
    end
  end

  def test_category_must_agree_with_category_for_except_not_found_may_use_nil_code
    error = assert_raises(ArgumentError) do
      valid_status(category: :finalized_paid, category_code: "F2")
    end

    assert_match(/category/i, error.message)

    not_found = valid_status(category: :not_found, category_code: nil, status_code: "21")

    assert not_found.category == :not_found
    assert_nil not_found.category_code
  end

  # -- predicate helpers -----------------------------------------------------

  def test_paid_denied_rejected_and_pending_helpers
    paid = valid_status(category: :finalized_paid, category_code: "F1",
                        paid_amount: BigDecimal("10.00"))
    denied = valid_status(category: :finalized_denied, category_code: "F2")
    rejected = valid_status(category: :rejected, category_code: "A7")
    pending = valid_status(category: :pending, category_code: "P1")

    assert paid.paid?
    refute paid.denied?
    refute paid.rejected?
    refute paid.pending?
    assert paid.final?

    refute denied.paid?
    assert denied.denied?
    refute denied.rejected?
    refute denied.pending?
    assert denied.final?

    refute rejected.paid?
    refute rejected.denied?, "rejected is front-end intake, not an adjudicated denial"
    assert rejected.rejected?
    refute rejected.pending?
    refute rejected.final?

    refute pending.paid?
    refute pending.final?
    assert pending.pending?
  end

  def test_rejected_and_denied_are_never_both_true
    rejected = valid_status(category: :rejected, category_code: "A7")
    denied = valid_status(category: :finalized_denied, category_code: "F2")

    refute(rejected.rejected? && rejected.denied?)
    refute(denied.rejected? && denied.denied?)
  end

  # -- clearinghouse base (typed seam, not the adapter hash) ---------------

  def test_the_clearinghouse_client_base_refuses_untyped_status_checks
    bare = Corvid::Rcm::ClearinghouseClient.new

    assert_raises(NotImplementedError) { bare.check_claim_status("CLM-1") }
  end

  def test_adapters_base_still_refuses_check_claim_status_in_plain_ruby
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "corvid/adapters/base"
      abort("ActiveRecord was loaded") if defined?(ActiveRecord::Base)
      abort("Rails was loaded") if defined?(Rails)
      bare = Corvid::Adapters::Base.new
      begin
        bare.check_claim_status("CLM-1")
        abort("expected NotImplementedError")
      rescue NotImplementedError
        # expected
      end
    RUBY

    assert system(RbConfig.ruby, "-I", lib, "-e", script),
           "Adapters::Base#check_claim_status must remain unimplemented on the adapter seam"
  end

  private

  def valid_status(**overrides)
    defaults = {
      claim_identifier: "CLM-1",
      payer_control_number: nil,
      category: :pending,
      category_code: "P1",
      status_code: "20",
      paid_amount: nil,
      paid_date: nil,
      as_of: FIXED_AS_OF
    }
    Corvid::Rcm::ClaimStatus.new(**defaults.merge(overrides))
  end
end
