# frozen_string_literal: true

require "minitest/autorun"
require "securerandom"
require "tmpdir"
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

class Corvid::Rcm::PayerDirectoryTest < Minitest::Test
  TRANSACTIONS = Corvid::Rcm::PayerDirectoryEntryTest::TRANSACTIONS

  def directory_class
    Corvid::Rcm::PayerDirectory
  end

  def transactions_yaml(overrides = {})
    TRANSACTIONS.map do |transaction|
      attrs = overrides.fetch(transaction, { supported: false, enrollment_required: false })
      supported = attrs.fetch(:supported)
      enrollment_required = attrs.fetch(:enrollment_required)
      [
        "      #{transaction}:",
        "        supported: #{supported.inspect}",
        "        enrollment_required: #{enrollment_required.inspect}"
      ].join("\n")
    end.join("\n")
  end

  def payer_row(payer_identifier:, name:, aliases: [], transaction_overrides: {})
    lines = [ "  - payer_identifier: #{payer_identifier}" ]
    if aliases.empty?
      lines << "    aliases: []"
    else
      lines << "    aliases:"
      aliases.each { |alias_id| lines << "      - #{alias_id}" }
    end
    lines << "    name: #{name}"
    lines << "    as_of: 2026-01-01"
    lines << "    transactions:"
    lines << transactions_yaml(transaction_overrides)
    lines.join("\n")
  end

  def write_directory(path, *payer_rows)
    File.write(path, "payers:\n#{payer_rows.join("\n")}\n")
  end

  def load_directory_at(path)
    directory_class.load(path)
  end

  def test_load_refuses_ambiguous_alias_and_identifier_collision_without_naming_either_identifier
    Dir.mktmpdir do |dir|
      path = File.join(dir, "payer_directory.yml")
      write_directory(
        path,
        payer_row(payer_identifier: "SYN99", name: "EXAMPLE SYN99 PAYER", aliases: [ "SYN12" ]),
        payer_row(payer_identifier: "SYN12", name: "EXAMPLE SYN12 PAYER")
      )

      error = assert_raises(ArgumentError) { load_directory_at(path) }

      refute_includes error.message, "SYN99"
      refute_includes error.message, "SYN12"
    end
  end

  def test_load_refuses_duplicate_payer_identifiers_without_naming_the_identifier
    Dir.mktmpdir do |dir|
      path = File.join(dir, "payer_directory.yml")
      write_directory(
        path,
        payer_row(payer_identifier: "EXDUP01", name: "EXAMPLE FIRST DUP PAYER"),
        payer_row(payer_identifier: "EXDUP01", name: "EXAMPLE SECOND DUP PAYER")
      )

      error = assert_raises(ArgumentError) { load_directory_at(path) }

      refute_includes error.message, "EXDUP01"
    end
  end

  def test_load_allows_an_alias_that_equals_the_rows_own_payer_identifier
    Dir.mktmpdir do |dir|
      path = File.join(dir, "payer_directory.yml")
      write_directory(
        path,
        payer_row(payer_identifier: "REDUN01", name: "EXAMPLE REDUNDANT ALIAS PAYER", aliases: [ "REDUN01" ])
      )

      directory = load_directory_at(path)

      assert_equal 1, directory.search("redun01").length
    end
  end

  def test_load_raises_argument_error_on_yaml_syntax_error_without_path_or_file_content
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.yml")
      marker = "SECRET_YAML_MARKER_#{SecureRandom.hex(8)}"
      File.write(path, "payers:\n  - payer_identifier: \"#{marker}\n")

      error = assert_raises(ArgumentError) { load_directory_at(path) }

      refute_includes error.message, path
      refute_includes error.message, marker
    end
  end

  def test_load_raises_argument_error_when_file_is_missing_without_path_in_message
    Dir.mktmpdir do |dir|
      path = File.join(dir, "no_such_payer_directory.yml")

      error = assert_raises(ArgumentError) { load_directory_at(path) }

      refute_includes error.message, path
      refute_includes error.message, "no_such_payer_directory.yml"
    end
  end
end

class Corvid::Rcm::ClearinghouseClientPayerSearchTest < Minitest::Test
  def test_search_payers_raises_not_implemented_on_the_base_class
    client = Corvid::Rcm::ClearinghouseClient.new

    assert_raises(NotImplementedError) { client.search_payers("x") }
  end
end
