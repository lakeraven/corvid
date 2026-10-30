# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"
require_relative "claim"

module Corvid
  module Rcm
    # Why a charge was not built, or why the set is incomplete.
    # `reference` is a FHIR reference, or nil when the problem describes the
    # encounter as a whole. Problems carry no names and no narrative.
    ChargeProblem = Data.define(:code, :reference) do
      def initialize(code:, reference: nil)
        super
      end
    end

    # In-memory charges for one encounter. `lines` are ClaimLines, `diagnoses`
    # are Diagnoses in claim order, and `coverage` has no subscriber
    # demographics. `rendering_provider_npi` is set only when every built line
    # names that same NPI.
    ChargeSet = Data.define(
      :encounter_reference,
      :lines,
      :diagnoses,
      :coverage,
      :problems,
      :rendering_provider_npi
    ) do
      def initialize(encounter_reference:, lines:, diagnoses:, coverage:, problems:,
                     rendering_provider_npi: nil)
        super(
          encounter_reference: encounter_reference,
          lines: lines.dup.freeze,
          diagnoses: diagnoses.dup.freeze,
          coverage: coverage,
          problems: problems.dup.freeze,
          rendering_provider_npi: rendering_provider_npi
        )
      end
    end

    # Builds claim lines from a finalized FHIR R4 encounter already in memory.
    # Inputs are resource hashes. Nothing is read from an adapter and nothing
    # is persisted.
    #
    # Only Encounter.status "finished" produces lines. An unknown modality
    # stops the build. A line is emitted when the procedure is completed, belongs
    # to this encounter, carries a code in the charge set, has a serviced date,
    # resolves at least one diagnosis, and has a finite non-negative BigDecimal
    # price from the injected price list. Anything short of that is a
    # ChargeProblem and not a line.
    #
    # Encounter diagnoses are listed in rank order (unranked ones keep their
    # original order after the ranked ones). Procedure.reasonReference, in that
    # order, supplies the line's diagnosis pointers. With no reasonReference the
    # line points at the principal encounter diagnosis.
    #
    # The charge set carries codes, amounts, dates, NPIs, and references.
    # Names, birth dates, addresses, and narrative text are never copied
    # (ADR 0003). Prices stay BigDecimal (ADR 0004).
    class ChargeBuilder
      CPT_SYSTEM = "http://www.ama-assn.org/go/cpt"
      HCPCS_SYSTEM = "https://www.cms.gov/Medicare/Coding/HCPCSReleaseCodeSets"
      ICD10_CM_SYSTEM = "http://hl7.org/fhir/sid/icd-10-cm"
      NPI_SYSTEM = "http://hl7.org/fhir/sid/us-npi"
      ACT_CODE_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-ActCode"
      LOCATION_PHYSICAL_TYPE_SYSTEM = "http://terminology.hl7.org/CodeSystem/location-physical-type"
      SNOMED_SYSTEM = "http://snomed.info/sct"
      AUDIO_ONLY_MODIFIER_EXTENSION = "https://corvid.example/fhir/StructureDefinition/audio-only-modifier"

      PROCEDURE_CODE_SYSTEMS = [ CPT_SYSTEM, HCPCS_SYSTEM ].freeze
      TELEPHONE_ENCOUNTER_CODE = "185317003"
      HOME_PHYSICAL_TYPE = "ho"
      AMBULATORY_CLASS = "AMB"
      VIRTUAL_CLASS = "VR"
      FINISHED_STATUS = "finished"
      COMPLETED_STATUS = "completed"

      # First behavioral-health charge set. Any other code is
      # :code_not_in_charge_set and does not become a line.
      CHARGE_CODES = %w[
        90791 90792 90832 90834
        90837 90846 90847 90853
      ].freeze

      # Place of service and modifiers for each ClaimLine modality. Kept in
      # step with place_of_service_matches_encounter_modality in
      # data/scrub_rules.yml. Audio-only uses POS 10 when the encounter
      # location physical type is home and POS 02 otherwise. Its modifier is
      # 93 unless Coverage#audio_only_modifier names the payer's code.
      MODALITY_BILLING = {
        in_person: { place_of_service: "11", modifiers: [].freeze }.freeze,
        telehealth_patient_home: { place_of_service: "10", modifiers: [ "95" ].freeze }.freeze,
        telehealth_other: { place_of_service: "02", modifiers: [ "95" ].freeze }.freeze,
        audio_only: {
          place_of_service: "02",
          home_place_of_service: "10",
          modifiers: [ "93" ].freeze
        }.freeze
      }.freeze

      # This charge set bills one unit per procedure. Session length is
      # documented_minutes, from performedPeriod, and is not a unit count.
      UNITS = 1
      CURRENCY = "USD"

      # Reads a FHIR hash. Missing keys and non-hash intermediates become nil.
      # Absent data is never defaulted here.
      class FhirHash
        WRITTEN_DATE = /\A(\d{4})-(\d{2})-(\d{2})(?:T|\z)/

        def initialize(value)
          @hash = value.is_a?(Hash) ? value : {}
        end

        def dig(*keys)
          self.class.dig_at(@hash, *keys)
        end

        def array(*keys)
          value = dig(*keys)
          value.is_a?(Array) ? value : []
        end

        def string_at(*keys)
          value = dig(*keys)
          value.is_a?(String) && !value.empty? ? value : nil
        end

        def reference(type)
          id = string_at("id")
          id.nil? ? nil : "#{type}/#{id}"
        end

        def self.dig_at(value, *keys)
          return nil unless value.is_a?(Hash)

          value.dig(*keys)
        rescue TypeError
          nil
        end

        def self.coded(node, system)
          return nil unless node.is_a?(Hash)
          return node["code"] if matching_code?(node, system)

          codes = node["coding"]
          return nil unless codes.is_a?(Array)

          codes.each do |coding|
            next unless coding.is_a?(Hash) && matching_code?(coding, system)

            return coding["code"]
          end
          nil
        end

        def self.procedure_code(codings)
          return nil unless codings.is_a?(Array)

          codings.each do |coding|
            next unless coding.is_a?(Hash) && PROCEDURE_CODE_SYSTEMS.include?(coding["system"])
            next unless matching_code_text?(coding["code"])

            return coding["code"]
          end
          nil
        end

        def self.reference_id(reference, type)
          return nil unless reference.is_a?(String)

          marker = "#{type}/"
          index = reference.rindex(marker)
          return nil if index.nil? || (index.positive? && reference[index - 1] != "/")

          id = reference[(index + marker.length)..]
          return nil if id.nil? || id.empty? || id.include?("/")

          id
        end

        def self.identifier_value(identifier)
          identifier_items(identifier).each do |item|
            value = item["value"]
            return value if value.is_a?(String) && !value.empty?
          end
          nil
        end

        def self.npi(identifier)
          identifier_items(identifier).each do |item|
            next unless item["system"] == NPI_SYSTEM

            value = item["value"]
            return value if value.is_a?(String) && !value.empty?
          end
          nil
        end

        # Calendar date as written on the FHIR date or dateTime. The offset is
        # not applied, so a late evening in a negative offset stays that date.
        def self.written_date(value)
          return nil unless value.is_a?(String)

          match = WRITTEN_DATE.match(value)
          return nil unless match

          Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
        rescue ArgumentError
          nil
        end

        def self.minutes_between(start_value, end_value)
          started = parsed_time(start_value)
          ended = parsed_time(end_value)
          return nil if started.nil? || ended.nil?

          elapsed = ended - started
          return nil unless elapsed.finite? && elapsed.positive?

          (elapsed / 60).floor
        end

        def payor_identifier
          array("payor").each do |payor|
            next unless payor.is_a?(Hash)

            value = self.class.identifier_value(payor["identifier"])
            return value if value
          end
          nil
        end

        def extension_code(url)
          array("extension").each do |extension|
            next unless extension.is_a?(Hash) && extension["url"] == url

            code = extension["valueCode"]
            return code if code.is_a?(String) && !code.empty?
          end
          nil
        end

        def self.identifier_items(identifier)
          case identifier
          when Hash then [ identifier ]
          when Array then identifier.select { |item| item.is_a?(Hash) }
          else []
          end
        end
        private_class_method :identifier_items

        def self.matching_code?(node, system)
          node["system"] == system && matching_code_text?(node["code"])
        end
        private_class_method :matching_code?

        def self.matching_code_text?(code)
          code.is_a?(String) && !code.empty?
        end
        private_class_method :matching_code_text?

        def self.parsed_time(value)
          return nil unless value.is_a?(String)

          Time.iso8601(value)
        rescue ArgumentError
          nil
        end
        private_class_method :parsed_time
      end

      # Claim diagnosis list. Encounter diagnoses are added first, in rank
      # order; procedure reasons append conditions that are not already listed.
      class DiagnosisList
        def initialize(conditions)
          @conditions = index_conditions(conditions)
          @items = []
          @sequences = {}
          @unresolved = {}
          @problems = []
          @principal_sequence = nil
        end

        attr_reader :items, :problems, :principal_sequence

        def add_encounter(references)
          references.each { |reference| add_reference(reference, claim_principal: true) }
        end

        def sequences_for(references)
          references.filter_map { |reference| add_reference(reference) }.uniq
        end

        private

        def index_conditions(conditions)
          index = {}
          return index unless conditions.is_a?(Array)

          conditions.each { |condition| store_condition(index, condition) }
          index
        end

        def store_condition(index, condition)
          return unless condition.is_a?(Hash)

          id = condition["id"]
          index[id] = condition if id.is_a?(String) && !id.empty?
        end

        def add_reference(reference, claim_principal: false)
          id = FhirHash.reference_id(reference, "Condition")
          sequence = id.nil? ? missing_reference : remember(id)
          @principal_sequence ||= sequence if claim_principal
          sequence
        end

        def remember(id)
          return @sequences[id] if @sequences.key?(id)
          return nil if @unresolved.key?(id)

          code = icd10_code(@conditions[id])
          return mark_unresolved(id) if code.nil?

          sequence = @items.length + 1
          @items << Diagnosis.new(sequence: sequence, code: code)
          @sequences[id] = sequence
        end

        def mark_unresolved(id)
          @unresolved[id] = true
          @problems << ChargeProblem.new(code: :diagnosis_unresolved, reference: "Condition/#{id}")
          nil
        end

        def missing_reference
          @problems << ChargeProblem.new(code: :diagnosis_unresolved, reference: nil)
          nil
        end

        def icd10_code(condition)
          return nil unless condition.is_a?(Hash)

          FhirHash.coded(condition["code"], ICD10_CM_SYSTEM)
        end
      end

      Modality = Data.define(:name, :place_of_service, :modifiers)

      def self.build(encounter:, procedures:, conditions:, coverage:, price_list:)
        new(encounter:, procedures:, conditions:, coverage:, price_list:).build
      end

      def initialize(encounter:, procedures:, conditions:, coverage:, price_list:)
        @encounter = FhirHash.new(encounter)
        @procedures = procedures.is_a?(Array) ? procedures : []
        @conditions = conditions.is_a?(Array) ? conditions : []
        @coverage = read_coverage(coverage)
        @price_list = price_list
        @problems = []
      end

      def build
        return unfinished_result unless finished?
        return unknown_modality_result if (@modality = resolve_modality).nil?

        assemble
      end

      private

      def unfinished_result
        result(problems: [ problem(:encounter_not_finished) ])
      end

      def unknown_modality_result
        result(problems: [ problem(:encounter_modality_unknown) ])
      end

      def assemble
        @diagnoses = DiagnosisList.new(@conditions)
        @diagnoses.add_encounter(ranked_condition_references)
        collect_lines
        rendering, extra = rendering_outcome
        result(
          lines: @lines,
          diagnoses: @diagnoses.items,
          problems: @diagnoses.problems + @problems + extra,
          rendering_provider_npi: rendering
        )
      end

      def collect_lines
        @lines = []
        @npis = []
        @line_refs = []
        @procedures.each { |procedure| consider_procedure(procedure) }
      end

      def consider_procedure(raw)
        return add_problem(:procedure_not_in_encounter) unless raw.is_a?(Hash)

        procedure = FhirHash.new(raw)
        reference = procedure.reference("Procedure")
        return add_problem(:procedure_not_in_encounter, reference) unless in_encounter?(procedure)
        return add_problem(:procedure_not_completed, reference) unless completed?(procedure)

        code = billable_code(procedure)
        return add_problem(:code_not_in_charge_set, reference) if code.nil?

        date = serviced_date(procedure)
        return add_problem(:serviced_date_missing, reference) if date.nil?

        sequences = diagnosis_sequences(procedure, reference)
        return if sequences.nil?

        build_priced_line(procedure, reference, code, date, sequences)
      end

      def build_priced_line(procedure, reference, code, date, sequences)
        amount = quoted_price(code)
        problem_code = price_problem(amount)
        return add_problem(problem_code, reference) if problem_code

        append_line(procedure, reference, code, date, sequences, amount)
      end

      def append_line(procedure, reference, code, date, sequences, amount)
        @lines << claim_line(procedure, code, date, sequences, amount)
        @npis << rendering_npi(procedure)
        @line_refs << reference
      end

      def claim_line(procedure, code, date, sequences, amount)
        ClaimLine.new(
          sequence: @lines.length + 1,
          procedure_code: code,
          modifiers: @modality.modifiers,
          place_of_service: @modality.place_of_service,
          encounter_modality: @modality.name,
          serviced_date: date,
          billed_amount: amount,
          currency: CURRENCY,
          units: UNITS,
          documented_minutes: documented_minutes(procedure),
          diagnosis_sequences: sequences.freeze
        )
      end

      def diagnosis_sequences(procedure, reference)
        reasons = reason_references(procedure)
        return fallback_diagnosis(reference) if reasons.nil?

        sequences = @diagnoses.sequences_for(reasons)
        sequences.empty? ? nil : sequences
      end

      def fallback_diagnosis(reference)
        principal = @diagnoses.principal_sequence
        return [ principal ] if principal

        add_problem(:no_diagnosis, reference)
        nil
      end

      def reason_references(procedure)
        refs = procedure.dig("reasonReference")
        return nil unless refs.is_a?(Array) && !refs.empty?

        refs.map { |item| item.is_a?(Hash) ? item["reference"] : nil }
      end

      def billable_code(procedure)
        code = FhirHash.procedure_code(procedure.dig("code", "coding"))
        CHARGE_CODES.include?(code) ? code : nil
      end

      def serviced_date(procedure)
        FhirHash.written_date(procedure.dig("performedDateTime")) ||
          FhirHash.written_date(procedure.dig("performedPeriod", "start"))
      end

      def documented_minutes(procedure)
        FhirHash.minutes_between(
          procedure.dig("performedPeriod", "start"),
          procedure.dig("performedPeriod", "end")
        )
      end

      def quoted_price(code)
        return nil unless @price_list.respond_to?(:call)

        @price_list.call(code, @modality.modifiers.dup)
      end

      def price_problem(amount)
        return :no_price if amount.nil?
        return nil if money?(amount)

        :invalid_price
      end

      def money?(amount)
        amount.is_a?(BigDecimal) && amount.finite? && amount >= 0
      end

      def rendering_npi(procedure)
        procedure.array("performer").each do |performer|
          next unless performer.is_a?(Hash)

          npi = FhirHash.npi(FhirHash.dig_at(performer, "actor", "identifier"))
          return npi if npi
        end
        nil
      end

      def rendering_outcome
        return [ nil, [] ] if @npis.empty?

        [ chosen_npi, rendering_problems ]
      end

      def chosen_npi
        distinct = @npis.uniq
        distinct.length == 1 ? distinct.first : nil
      end

      def rendering_problems
        problems = missing_npi_problems
        problems << problem(:multiple_rendering_providers) if @npis.compact.uniq.length > 1
        problems
      end

      def missing_npi_problems
        @npis.each_with_index.filter_map do |npi, index|
          problem(:rendering_provider_missing, @line_refs[index]) if npi.nil?
        end
      end

      def in_encounter?(procedure)
        id = encounter_id
        return false if id.nil?

        FhirHash.reference_id(procedure.dig("encounter", "reference"), "Encounter") == id
      end

      def completed?(procedure)
        procedure.dig("status") == COMPLETED_STATUS
      end

      def finished?
        @encounter.dig("status") == FINISHED_STATUS
      end

      def encounter_id
        @encounter.string_at("id")
      end

      def resolve_modality
        case class_code
        when AMBULATORY_CLASS then modality_row(:in_person)
        when VIRTUAL_CLASS then virtual_modality
        end
      end

      def virtual_modality
        return audio_modality if audio_only?
        return modality_row(:telehealth_patient_home) if patient_home?

        modality_row(:telehealth_other)
      end

      def audio_modality
        row = MODALITY_BILLING.fetch(:audio_only)
        place = patient_home? ? row[:home_place_of_service] : row[:place_of_service]
        Modality.new(name: :audio_only, place_of_service: place, modifiers: audio_modifiers(row))
      end

      def modality_row(name)
        row = MODALITY_BILLING.fetch(name)
        Modality.new(
          name: name,
          place_of_service: row[:place_of_service],
          modifiers: row[:modifiers].dup.freeze
        )
      end

      def audio_modifiers(row)
        override = @coverage&.audio_only_modifier
        chosen = override.nil? || override.empty? ? row[:modifiers] : [ override ]
        chosen.dup.freeze
      end

      def class_code
        FhirHash.coded(@encounter.dig("class"), ACT_CODE_SYSTEM)
      end

      def audio_only?
        @encounter.array("type").any? do |type|
          FhirHash.coded(type, SNOMED_SYSTEM) == TELEPHONE_ENCOUNTER_CODE
        end
      end

      def patient_home?
        @encounter.array("location").any? do |location|
          next false unless location.is_a?(Hash)

          FhirHash.coded(location["physicalType"], LOCATION_PHYSICAL_TYPE_SYSTEM) == HOME_PHYSICAL_TYPE
        end
      end

      def ranked_condition_references
        diagnosis_entries.sort_by { |entry, index| rank_key(entry, index) }
                         .map { |entry, _index| FhirHash.dig_at(entry, "condition", "reference") }
      end

      def diagnosis_entries
        @encounter.array("diagnosis").each_with_index.filter_map do |entry, index|
          [ entry, index ] if entry.is_a?(Hash)
        end
      end

      def rank_key(entry, index)
        rank = entry["rank"]
        rank.is_a?(Integer) ? [ 0, rank, index ] : [ 1, 0, index ]
      end

      def read_coverage(raw)
        return nil unless raw.is_a?(Hash)

        fhir = FhirHash.new(raw)
        Coverage.new(
          payer_identifier: fhir.payor_identifier,
          identifier: FhirHash.identifier_value(fhir.dig("identifier")),
          status: fhir.string_at("status"),
          relationship: nil,
          audio_only_modifier: fhir.extension_code(AUDIO_ONLY_MODIFIER_EXTENSION)
        )
      end

      def result(lines: [], diagnoses: [], problems: [], rendering_provider_npi: nil)
        ChargeSet.new(
          encounter_reference: @encounter.reference("Encounter"),
          lines: lines,
          diagnoses: diagnoses,
          coverage: @coverage,
          problems: problems,
          rendering_provider_npi: rendering_provider_npi
        )
      end

      def problem(code, reference = nil)
        ChargeProblem.new(code: code, reference: reference)
      end

      def add_problem(code, reference = nil)
        @problems << problem(code, reference)
      end

      private_constant :FhirHash, :DiagnosisList, :Modality
    end
  end
end
