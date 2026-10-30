# frozen_string_literal: true

require "minitest/autorun"
require "corvid/rcm"

class Corvid::Rcm::PayerDirectoryEntryTest < Minitest::Test
  TRANSACTIONS = %i[
    professional_claim
    institutional_claim
    dental_claim
    remittance
    eligibility
    claim_status
    coverage_discovery
    coordination_of_benefits
    paper_claim
  ].freeze

  def entry_class
    Corvid::Rcm::PayerDirectoryEntry
  end

  def entry(payer_identifier: "TESTPAY01", aliases: [], name: "TEST PAYER",
            transactions: {}, as_of: Date.new(2026, 6, 15))
    entry_class.new(
      payer_identifier: payer_identifier,
      aliases: aliases,
      name: name,
      transactions: transactions,
      as_of: as_of
    )
  end

  def tx(supported:, enrollment_required:)
    { supported: supported, enrollment_required: enrollment_required }
  end

  # -- shape -----------------------------------------------------------------

  def test_it_is_a_data_object_with_the_payer_directory_members
    assert_equal %i[payer_identifier aliases name transactions as_of], entry_class.members
  end

  def test_as_of_is_a_date
    assert_kind_of Date, entry(as_of: Date.new(2026, 3, 1)).as_of
  end

  def test_aliases_and_transactions_are_frozen_copies_isolated_from_caller_mutation
    aliases = [ "ALT-A" ]
    transactions = {
      professional_claim: tx(supported: true, enrollment_required: false)
    }
    directory_entry = entry(aliases: aliases, transactions: transactions)

    aliases << "ALT-B"
    transactions[:professional_claim][:supported] = false

    assert_equal [ "ALT-A" ], directory_entry.aliases
    assert directory_entry.supports?(:professional_claim)
    assert_predicate directory_entry.aliases, :frozen?
    assert_predicate directory_entry.transactions, :frozen?
  end

  # -- supports? -------------------------------------------------------------

  def test_supports_true_only_for_an_explicit_true
    directory_entry = entry(transactions: {
                              professional_claim: tx(supported: true, enrollment_required: false)
                            })

    assert directory_entry.supports?(:professional_claim)
  end

  def test_supports_false_for_explicit_false_nil_and_absent_transaction
    with_false = entry(transactions: {
                         eligibility: tx(supported: false, enrollment_required: false)
                       })
    with_nil = entry(transactions: {
                       eligibility: tx(supported: nil, enrollment_required: false)
                     })
    absent = entry(transactions: {})

    refute with_false.supports?(:eligibility)
    refute with_nil.supports?(:eligibility)
    refute absent.supports?(:professional_claim)
  end

  def test_supports_false_for_non_boolean_truthy_supported_values
    directory_entry = entry(transactions: {
                              professional_claim: tx(supported: "yes", enrollment_required: false),
                              remittance: tx(supported: 1, enrollment_required: false)
                            })

    refute directory_entry.supports?(:professional_claim)
    refute directory_entry.supports?(:remittance)
  end

  def test_supports_raises_for_unknown_transaction_symbols
    directory_entry = entry

    assert_raises(ArgumentError) { directory_entry.supports?(:dentl) }
  end

  def test_supports_raises_for_string_transaction_names
    directory_entry = entry

    assert_raises(ArgumentError) { directory_entry.supports?("eligibility") }
  end

  # -- enrollment_required? --------------------------------------------------

  def test_enrollment_required_false_only_for_an_explicit_false
    directory_entry = entry(transactions: {
                              remittance: tx(supported: true, enrollment_required: false)
                            })

    refute directory_entry.enrollment_required?(:remittance)
  end

  def test_enrollment_required_true_for_true_nil_and_absent_transaction
    required = entry(transactions: {
                       remittance: tx(supported: true, enrollment_required: true)
                     })
    unknown = entry(transactions: {
                      remittance: tx(supported: true, enrollment_required: nil)
                    })
    absent = entry(transactions: {})

    assert required.enrollment_required?(:remittance)
    assert unknown.enrollment_required?(:remittance)
    assert absent.enrollment_required?(:eligibility)
  end

  def test_enrollment_required_true_for_non_boolean_values
    directory_entry = entry(transactions: {
                              eligibility: tx(supported: true, enrollment_required: "no"),
                              remittance: tx(supported: true, enrollment_required: 0)
                            })

    assert directory_entry.enrollment_required?(:eligibility)
    assert directory_entry.enrollment_required?(:remittance)
  end

  def test_enrollment_required_raises_for_unknown_transaction_symbols
    directory_entry = entry

    assert_raises(ArgumentError) { directory_entry.enrollment_required?(:dentl) }
  end

  def test_enrollment_required_raises_for_string_transaction_names
    directory_entry = entry

    assert_raises(ArgumentError) { directory_entry.enrollment_required?("eligibility") }
  end

  # -- constructor validation ------------------------------------------------

  def test_constructing_with_an_unknown_transaction_key_raises
    assert_raises(ArgumentError) do
      entry(transactions: { dentl: tx(supported: true, enrollment_required: false) })
    end
  end

  # -- matches? --------------------------------------------------------------

  def test_matches_primary_identifier_case_insensitively_and_strips_whitespace
    directory_entry = entry(payer_identifier: "EXCOMM01")

    assert directory_entry.matches?("excomm01")
    assert directory_entry.matches?("  EXCOMM01  ")
  end

  def test_matches_each_alias_case_insensitively_and_strips_whitespace
    directory_entry = entry(payer_identifier: "EXCOMM01", aliases: [ "EXCOMM-ALT" ])

    assert directory_entry.matches?("excomm-alt")
    assert directory_entry.matches?("  EXCOMM-ALT ")
  end

  def test_matches_rejects_nil_blank_prefix_and_substring_identifiers
    directory_entry = entry(payer_identifier: "EXMCD01", aliases: [ "EXMCD-ALT" ])

    refute directory_entry.matches?(nil)
    refute directory_entry.matches?("")
    refute directory_entry.matches?("   ")
    refute directory_entry.matches?("EXMCD")
    refute directory_entry.matches?("EXMCD01X")
    refute directory_entry.matches?("ALT")
  end
end

class Corvid::Rcm::ClearinghouseClientPayerSearchTest < Minitest::Test
  def test_search_payers_raises_not_implemented_on_the_base_class
    client = Corvid::Rcm::ClearinghouseClient.new

    assert_raises(NotImplementedError) { client.search_payers("x") }
  end
end
