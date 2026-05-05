# frozen_string_literal: true

module Corvid
  # Registry of programs Corvid can manage. Programs are identified by a
  # string code; each program declares an optional milestone ladder used by
  # ProgramTemplateService when materializing a case.
  #
  # Built-in entries cover the IHS programs the engine ships with. Hosts can
  # register additional programs (CMMI models, state Medicaid initiatives,
  # commercial programs) from an initializer:
  #
  #   Corvid::ProgramRegistry.register(
  #     "access_bh",
  #     display_name: "ACCESS Behavioral Health",
  #     milestones: [
  #       { key: "initial_phq9", description: "Initial PHQ-9", days_after_anchor: 0, required: true },
  #       ...
  #     ]
  #   )
  #
  # Replaces the previous fixed Case::PROGRAM_TYPES enum so non-IHS programs
  # can enroll without engine forks.
  module ProgramRegistry
    Entry = Struct.new(:code, :display_name, :milestones, keyword_init: true)

    DEFAULTS = [
      {
        code: "tb",
        display_name: "Tuberculosis",
        milestones: [
          { key: "initial_skin_test", description: "Initial TST/IGRA test", days_after_anchor: 0, required: true },
          { key: "chest_xray", description: "Chest X-ray", days_after_anchor: 7, required: true },
          { key: "treatment_start", description: "Start treatment", days_after_anchor: 14, required: true },
          { key: "followup_6mo", description: "6-month follow-up", days_after_anchor: 180, required: true }
        ]
      },
      {
        code: "hep_b",
        display_name: "Hepatitis B Perinatal",
        milestones: [
          { key: "hbig_administration", description: "HBIG administration within 12 hours", days_after_anchor: 0, required: true },
          { key: "hepb_dose_1", description: "Hep B vaccine dose 1", days_after_anchor: 0, required: true },
          { key: "hepb_dose_2", description: "Hep B vaccine dose 2", days_after_anchor: 30, required: true },
          { key: "hepb_dose_3", description: "Hep B vaccine dose 3", days_after_anchor: 180, required: true },
          { key: "post_vaccination_test", description: "Post-vaccination serology", days_after_anchor: 270, required: true }
        ]
      },
      {
        code: "immunization",
        display_name: "Routine Immunization",
        milestones: [
          { key: "review_record", description: "Review immunization record", days_after_anchor: 0, required: true },
          { key: "administer", description: "Administer vaccines", days_after_anchor: 1, required: true }
        ]
      },
      { code: "sti", display_name: "STI", milestones: [] },
      { code: "neonatal", display_name: "Neonatal", milestones: [] },
      { code: "lead", display_name: "Lead Exposure", milestones: [] },
      { code: "communicable_disease", display_name: "Communicable Disease", milestones: [] }
    ].freeze

    REQUIRED_MILESTONE_FIELDS = %i[key description days_after_anchor].freeze

    class << self
      def register(code, display_name:, milestones: [])
        ensure_loaded
        code = code.to_s
        @entries[code] = build_entry(code, display_name, milestones)
      end

      def find(code)
        ensure_loaded
        @entries[code.to_s]
      end

      def codes
        ensure_loaded
        @entries.keys
      end

      def exists?(code)
        ensure_loaded
        @entries.key?(code.to_s)
      end

      # Drop host registrations and reload defaults. Used by the engine boot
      # path and by tests that want a known-good baseline.
      def reset!
        @entries = nil
        @loaded = false
        ensure_loaded
      end

      # Drop everything, including defaults. Used by tests that need a truly
      # empty registry to verify a missing-program code path.
      def clear!
        @entries = {}
        @loaded = true
      end

      private

      def ensure_loaded
        return if @loaded

        @entries = {}
        DEFAULTS.each do |attrs|
          @entries[attrs[:code]] = build_entry(attrs[:code], attrs[:display_name], attrs[:milestones])
        end
        @loaded = true
      end

      def build_entry(code, display_name, milestones)
        Entry.new(
          code: code,
          display_name: display_name,
          milestones: milestones.map { |m| normalize_milestone(m) }.freeze
        )
      end

      # Accept symbol- or string-keyed hashes (common when programs come from
      # YAML / JSON config). Validate required fields up-front so a host
      # gets a clear ArgumentError at registration rather than a confusing
      # nil-attribute error later when ProgramTemplateService creates tasks.
      def normalize_milestone(milestone)
        unless milestone.is_a?(Hash)
          raise ArgumentError, "milestone must be a Hash, got #{milestone.class}"
        end

        m = milestone.transform_keys(&:to_sym)

        REQUIRED_MILESTONE_FIELDS.each do |field|
          if !m.key?(field) || (m[field].is_a?(String) && m[field].empty?) || m[field].nil?
            raise ArgumentError, "milestone is missing required field :#{field} (got #{milestone.inspect})"
          end
        end

        unless m[:days_after_anchor].is_a?(Integer)
          raise ArgumentError, "milestone :days_after_anchor must be Integer, got #{m[:days_after_anchor].class} (#{milestone.inspect})"
        end

        required = m.fetch(:required, false)
        unless required == true || required == false
          raise ArgumentError, "milestone :required must be true or false, got #{required.inspect} (#{milestone.inspect})"
        end

        {
          key: m[:key].to_s,
          description: m[:description].to_s,
          days_after_anchor: m[:days_after_anchor],
          required: required
        }.freeze
      end
    end
  end
end
