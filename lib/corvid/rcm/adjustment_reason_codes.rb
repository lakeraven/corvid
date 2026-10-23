# frozen_string_literal: true

require "yaml"

module Corvid
  module Rcm
    # The classification of one CAS adjustment: what the payer said, what to do
    # about it, and where it goes.
    #
    # `mapped` is the load-bearing field. An unmapped code is not an error and
    # not a guess — it is work for a person, and it can never be auto-closed.
    AdjustmentClassification = Data.define(
      :code, :reason, :action, :work_queue, :disposition, :mapped, :auto_postable
    ) do
      def mapped?
        mapped
      end

      def unmapped?
        !mapped
      end

      def denial?
        disposition == :denial
      end

      def patient_responsibility?
        disposition == :patient_responsibility
      end

      def contractual?
        disposition == :contractual
      end

      # Whether posting this adjustment may close the claim without a human
      # looking at it. Unmapped codes are never auto-closeable — that rule is
      # enforced here in code, not left to the data file to remember.
      def auto_closeable?
        mapped? && auto_postable
      end
    end

    # Loads the CARC/RARC table from YAML and answers lookups. The table is
    # data; the "unmapped goes to a human" rule is code.
    class AdjustmentReasonCodes
      DEFAULT_PATH = File.expand_path("data/adjustment_reason_codes.yml", __dir__)

      # Where an unrecognised code goes. Never auto-closed, never guessed at.
      HUMAN_REVIEW_QUEUE = :human_review

      UNMAPPED_ACTION = "Unrecognised adjustment reason code — Corvid will not guess at it. " \
                        "A billing lead must read the payer's remittance, decide the correct " \
                        "handling, and add the code to the mapping table so the next one routes " \
                        "itself. Do not close this claim until that happens."

      class << self
        def default
          @default ||= load(DEFAULT_PATH)
        end

        def load(path)
          new(YAML.safe_load_file(path, permitted_classes: [ Date ]))
        end

        # Convenience for the common case.
        def classify(code)
          default.classify(code)
        end

        def reset_default!
          @default = nil
        end
      end

      attr_reader :version, :effective_start

      def initialize(table)
        @version = table["version"]
        @effective_start = table["effective_start"]
        @carc = table.fetch("carc", {})
        @rarc = table.fetch("rarc", {})
        @dispositions = table.fetch("dispositions", {})
      end

      def mapped_codes
        @carc.keys
      end

      def mapped?(code)
        @carc.key?(normalize(code))
      end

      # Returns an AdjustmentClassification for any code — mapped or not.
      # Never returns nil, never raises on an unknown code: an unknown code is
      # a routine operational event, not an exception.
      def classify(code)
        key = normalize(code)
        entry = @carc[key]
        return unmapped_classification(key) if entry.nil?

        AdjustmentClassification.new(
          code: key,
          reason: entry.fetch("reason"),
          action: entry.fetch("action"),
          work_queue: entry.fetch("queue").to_sym,
          disposition: entry.fetch("disposition").to_sym,
          mapped: true,
          auto_postable: entry.fetch("auto_postable", false)
        )
      end

      # Human-readable text for a RARC remark code, or nil when unmapped. RARCs
      # qualify a CARC; they never drive routing on their own.
      def remark(code)
        @rarc[code.to_s]
      end

      def disposition_description(disposition)
        @dispositions[disposition.to_s]
      end

      private

      def normalize(code)
        code.to_s.strip.upcase
      end

      def unmapped_classification(code)
        AdjustmentClassification.new(
          code: code,
          reason: "No mapping on file for adjustment reason code #{code}.",
          action: UNMAPPED_ACTION,
          work_queue: HUMAN_REVIEW_QUEUE,
          disposition: :unmapped,
          mapped: false,
          auto_postable: false
        )
      end
    end
  end
end
