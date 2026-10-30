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
    #
    # A malformed file raises `ArgumentError` with a fixed message. The
    # message does not include the path, the payer, or the offending value,
    # so a directory cannot leak its contents through an exception.
    class PayerDirectory
      DEFAULT_PATH = File.expand_path("data/payer_directory.yml", __dir__)
      INVALID_ENTRY = "invalid payer directory entry"
      ENTRY_KEYS = %w[payer_identifier aliases name transactions as_of].freeze
      TRANSACTION_FIELDS = %w[supported enrollment_required].freeze

      class << self
        def load(path = DEFAULT_PATH)
          new(read_entries(path))
        end

        private

        def read_entries(path)
          entries_from(YAML.safe_load_file(path, permitted_classes: [ Date ]))
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

      def initialize(entries)
        @entries = entries.freeze
      end

      # Blank queries match nothing. Otherwise a payer is returned when the
      # query occurs in its name, payer identifier, or an alias, or when
      # `matches?` accepts the query as that identifier. Comparison is
      # case-insensitive, and whitespace around the query is ignored.
      # Each payer is returned at most once, in file order.
      def search(query)
        needle = query.to_s.strip.downcase
        return [] if needle.empty?

        @entries.select { |entry| hit?(entry, needle) }
      end

      private

      def hit?(entry, needle)
        entry.matches?(needle) || searchable_values(entry).any? { |value| includes_needle?(value, needle) }
      end

      def searchable_values(entry)
        [ entry.name, entry.payer_identifier, *entry.aliases ]
      end

      def includes_needle?(value, needle)
        value.to_s.strip.downcase.include?(needle)
      end
    end
  end
end
