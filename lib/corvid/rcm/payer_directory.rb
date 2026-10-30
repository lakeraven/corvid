# frozen_string_literal: true

require "date"
require "yaml"

module Corvid
  module Rcm
    # Transactions a directory row can describe. Anything else is refused
    # with a message that names this set and nothing about the payer.
    PAYER_DIRECTORY_TRANSACTIONS = %i[
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

    PAYER_DIRECTORY_UNKNOWN_TRANSACTION = (
      "unknown payer directory transaction (allowed: #{PAYER_DIRECTORY_TRANSACTIONS.join(", ")})"
    ).freeze

    PAYER_DIRECTORY_ABSENT_TRANSACTION = { supported: nil, enrollment_required: nil }.freeze

    # One payer's directory row: who they are, and which transactions they
    # accept.
    #
    # `supports?` is true only for an explicit true. `enrollment_required?`
    # is false only for an explicit false. Unknown support still requires
    # enrollment, because sending a transaction the payer has not agreed to
    # accept is how claims vanish. `matches?` compares a payer id or alias
    # exactly, ignoring case and surrounding whitespace.
    PayerDirectoryEntry = Data.define(
      :payer_identifier,
      :aliases,
      :name,
      :transactions,
      :as_of
    ) do
      def initialize(payer_identifier:, aliases:, name:, transactions:, as_of:)
        super(
          payer_identifier: freeze_copy(payer_identifier),
          aliases: freeze_aliases(aliases),
          name: freeze_copy(name),
          transactions: freeze_transactions(transactions),
          as_of: as_of
        )
      end

      def supports?(transaction)
        transaction_attrs(transaction)[:supported].equal?(true)
      end

      # False only when the directory explicitly says enrollment is not
      # required. A missing row, a null, or a non-boolean all require it.
      def enrollment_required?(transaction)
        !transaction_attrs(transaction)[:enrollment_required].equal?(false)
      end

      def matches?(identifier)
        candidate = canonical_identifier(identifier)
        return false if candidate.empty?

        known_identifiers.any? { |known| canonical_identifier(known) == candidate }
      end

      private

      def transaction_attrs(transaction)
        raise ArgumentError, PAYER_DIRECTORY_UNKNOWN_TRANSACTION unless PAYER_DIRECTORY_TRANSACTIONS.include?(transaction)

        transactions.fetch(transaction, PAYER_DIRECTORY_ABSENT_TRANSACTION)
      end

      def known_identifiers
        [ payer_identifier, *aliases ]
      end

      def canonical_identifier(value)
        value.to_s.strip.downcase
      end

      def freeze_aliases(aliases)
        Array(aliases).map { |alias_id| freeze_copy(alias_id) }.freeze
      end

      def freeze_transactions(transactions)
        raise ArgumentError, PAYER_DIRECTORY_UNKNOWN_TRANSACTION unless transactions.is_a?(Hash)

        transactions.each_with_object({}) do |(key, attrs), copy|
          copy[transaction_key!(key)] = freeze_attrs(attrs)
        end.freeze
      end

      def transaction_key!(key)
        symbol = key.to_sym if key.is_a?(String) || key.is_a?(Symbol)
        raise ArgumentError, PAYER_DIRECTORY_UNKNOWN_TRANSACTION unless PAYER_DIRECTORY_TRANSACTIONS.include?(symbol)

        symbol
      end

      def freeze_attrs(attrs)
        {
          supported: freeze_copy(attr_value(attrs, :supported)),
          enrollment_required: freeze_copy(attr_value(attrs, :enrollment_required))
        }.freeze
      end

      def attr_value(attrs, key)
        return nil unless attrs.is_a?(Hash)
        return attrs[key] if attrs.key?(key)
        return attrs[key.to_s] if attrs.key?(key.to_s)

        nil
      end

      def freeze_copy(value)
        value.is_a?(String) ? value.dup.freeze : value
      end
    end

    # A checked-in payer directory. The file is data; the rules for what
    # "supported" and "enrollment required" mean live on `PayerDirectoryEntry`.
    # `#search` returns payers whose name contains the stripped,
    # case-insensitive query, or whose payer identifier or an alias exactly
    # matches it. Identifiers and aliases are never matched by substring.
    # Exact identifier and alias matches come first, then name-substring
    # matches, each in file order, with no duplicates. Blank, whitespace-only,
    # and nil queries return nothing.
    #
    # Loading refuses an ambiguous directory: two rows sharing a payer
    # identifier, or an identifier or alias of one row equal (case-insensitive,
    # stripped) to an identifier or alias of another row. An alias equal to
    # its own row's identifier is allowed. `#initialize` runs that same check,
    # so `new` refuses two entries that share an identifier or alias. A
    # duplicate mapping key anywhere in the document is refused, and so is a
    # merge key (`<<`) anywhere in the node tree. The loader uses
    # `Psych.parse_stream` and refuses a stream that is not exactly one
    # document. `supported` and `enrollment_required` must be plain scalars
    # whose text is exactly `true`, `false`, `null`, `~`, or empty; YAML 1.1
    # synonyms (`yes`, `no`, `on`, `off`, `y`, `n`) and other casings are
    # refused on the node tree before conversion. An ambiguous directory, a
    # malformed entry, a duplicate mapping key, a merge key, an extra
    # document, a non-literal support or enrollment value, a YAML syntax
    # error, or a missing or unreadable file raises `ArgumentError` with a
    # fixed message that includes no path, identifier, or file content. A
    # duplicate mapping key, a merge key, an extra document, a non-literal
    # support or enrollment value, an ambiguous directory, a YAML load error,
    # or a missing or unreadable file is raised with a nil cause.
    class PayerDirectory
      DEFAULT_PATH = File.expand_path("data/payer_directory.yml", __dir__)
      INVALID_ENTRY = "invalid payer directory entry"
      ENTRY_KEYS = %w[payer_identifier aliases name transactions as_of].freeze
      TRANSACTION_FIELDS = %w[supported enrollment_required].freeze
      # Plain-scalar text accepted for `supported` and `enrollment_required`
      # before Psych converts the node. Empty is a null scalar.
      ACCEPTED_FLAG_TEXTS = [ "true", "false", "null", "~", "" ].freeze

      class << self
        def load(path = DEFAULT_PATH)
          new(read_entries(path))
        end

        private

        def read_entries(path)
          entries_from(load_document(path))
        end

        # Psych quotes the path and can quote the line. The operating system
        # quotes the path for a missing or unreadable file. The parsed stream
        # must contain exactly one document. Duplicate mapping keys, merge
        # keys, and non-literal `supported` or `enrollment_required` scalars
        # are refused from the node tree before the document is converted to
        # Ruby, so a merge cannot insert a value and Psych cannot coerce a
        # YAML 1.1 boolean. The fixed message replaces the original, and a
        # nil cause drops it so it cannot leak.
        def load_document(path)
          contents = File.open(path, "r:bom|utf-8", &:read)
          reject_disallowed_nodes!(single_document_stream!(contents))
          YAML.safe_load(contents, permitted_classes: [ Date ], aliases: false)
        rescue Psych::Exception, SystemCallError
          raise ArgumentError, INVALID_ENTRY, cause: nil
        end

        def single_document_stream!(contents)
          stream = Psych.parse_stream(contents)
          raise ArgumentError, INVALID_ENTRY, cause: nil unless single_document?(stream)

          stream
        end

        def single_document?(stream)
          stream.is_a?(Psych::Nodes::Stream) && stream.children.length == 1
        end

        # Psych keeps the last duplicate key when it builds a Hash, and a
        # merge key folds another mapping into it. Walk scalar keys before
        # that conversion. Refuse `<<` wherever it is a mapping key. Refuse
        # `supported` and `enrollment_required` unless the value is a plain
        # scalar whose text is `true`, `false`, `null`, `~`, or empty.
        def reject_disallowed_nodes!(node)
          return unless node.is_a?(Psych::Nodes::Node)

          raise ArgumentError, INVALID_ENTRY, cause: nil if disallowed_mapping?(node)
          return if node.children.nil?

          node.children.each { |child| reject_disallowed_nodes!(child) }
        end

        def disallowed_mapping?(node)
          return false unless node.is_a?(Psych::Nodes::Mapping)

          seen = {}
          node.children.each_slice(2) do |key, value|
            next unless key.is_a?(Psych::Nodes::Scalar)
            return true if disallowed_scalar_entry?(key, value, seen)

            seen[key.value] = true
          end
          false
        end

        def disallowed_scalar_entry?(key, value, seen)
          merge_key?(key) || seen[key.value] || disallowed_flag_value?(key, value)
        end

        def merge_key?(key)
          key.value == "<<"
        end

        def disallowed_flag_value?(key, value)
          TRANSACTION_FIELDS.include?(key.value) && !accepted_flag_scalar?(value)
        end

        def accepted_flag_scalar?(value)
          value.is_a?(Psych::Nodes::Scalar) && value.plain && ACCEPTED_FLAG_TEXTS.include?(value.value)
        end

        def entries_from(document)
          raise ArgumentError, INVALID_ENTRY unless document.is_a?(Hash)

          rows = document["payers"]
          raise ArgumentError, INVALID_ENTRY unless rows.is_a?(Array)

          rows.map { |row| build_entry(row) }
        end

        def build_entry(row)
          validate_entry!(row)
          PayerDirectoryEntry.new(
            payer_identifier: row["payer_identifier"],
            aliases: row["aliases"],
            name: row["name"],
            transactions: symbolized_transactions(row["transactions"]),
            as_of: row["as_of"]
          )
        end

        def symbolized_transactions(transactions)
          transactions.each_with_object({}) do |(name, attrs), converted|
            converted[name.to_sym] = {
              supported: attrs["supported"],
              enrollment_required: attrs["enrollment_required"]
            }
          end
        end

        def validate_entry!(row)
          raise ArgumentError, INVALID_ENTRY unless row.is_a?(Hash) && valid_entry_keys?(row)

          validate_text!(row["payer_identifier"])
          validate_text!(row["name"])
          validate_aliases!(row["aliases"])
          validate_as_of!(row["as_of"])
          validate_transactions!(row["transactions"])
        end

        def valid_entry_keys?(row)
          keys = row.keys
          keys.size == ENTRY_KEYS.size && ENTRY_KEYS.all? { |key| keys.include?(key) }
        end

        def validate_text!(value)
          raise ArgumentError, INVALID_ENTRY unless text?(value)
        end

        def validate_aliases!(aliases)
          raise ArgumentError, INVALID_ENTRY unless aliases.is_a?(Array) && aliases.all? { |alias_id| text?(alias_id) }
        end

        def validate_as_of!(value)
          raise ArgumentError, INVALID_ENTRY unless value.instance_of?(Date)
        end

        def validate_transactions!(transactions)
          raise ArgumentError, INVALID_ENTRY unless transactions.is_a?(Hash)

          transactions.each { |name, attrs| validate_transaction!(name, attrs) }
        end

        def validate_transaction!(name, attrs)
          raise ArgumentError, INVALID_ENTRY unless known_transaction_name?(name) && valid_transaction?(attrs)
        end

        def known_transaction_name?(name)
          name.is_a?(String) && PAYER_DIRECTORY_TRANSACTIONS.any? { |symbol| symbol.to_s == name }
        end

        def valid_transaction?(attrs)
          valid_transaction_fields?(attrs) && valid_transaction_values?(attrs)
        end

        def valid_transaction_fields?(attrs)
          return false unless attrs.is_a?(Hash)

          keys = attrs.keys
          keys.size == TRANSACTION_FIELDS.size && TRANSACTION_FIELDS.all? { |key| keys.include?(key) }
        end

        def valid_transaction_values?(attrs)
          TRANSACTION_FIELDS.all? { |key| boolean_or_nil?(attrs[key]) }
        end

        def boolean_or_nil?(value)
          value.equal?(true) || value.equal?(false) || value.nil?
        end

        def text?(value)
          value.is_a?(String) && !value.strip.empty?
        end
      end

      # Same ambiguity rule as a directory loaded from YAML.
      def initialize(entries)
        @entries = reject_ambiguous!(entries).freeze
      end

      # Blank, whitespace-only, and nil queries return nothing. A payer is
      # returned when its name contains the stripped, case-insensitive query,
      # or when its payer identifier or an alias exactly matches
      # (`PayerDirectoryEntry#matches?`). Identifiers and aliases are never
      # matched by substring. Exact identifier and alias matches come first,
      # then name-substring matches, each in file order, with no duplicates.
      def search(query)
        needle = query.to_s.strip.downcase
        return [] if needle.empty?

        exact, rest = @entries.partition { |entry| entry.matches?(needle) }
        exact + rest.select { |entry| name_contains?(entry, needle) }
      end

      private

      def reject_ambiguous!(entries)
        accepted = []
        entries.each do |entry|
          raise ArgumentError, INVALID_ENTRY, cause: nil if ambiguous_entry?(entry, accepted)

          accepted << entry
        end
        entries
      end

      # Cross-row only. `matches?` is exact, case-insensitive, and stripped.
      # The row is not compared with itself, so an alias equal to its own
      # identifier is allowed.
      def ambiguous_entry?(entry, accepted)
        [ entry.payer_identifier, *entry.aliases ].any? do |identifier|
          accepted.any? { |prior| prior.matches?(identifier) }
        end
      end

      def name_contains?(entry, needle)
        entry.name.to_s.downcase.include?(needle)
      end
    end
  end
end
