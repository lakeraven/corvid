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
    # names that same Practitioner NPI.
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
    # Only Encounter.status "finished" produces lines. An unknown or
    # contradictory modality stops the build. Class must come from v3-ActCode;
    # ambulatory together with a telephone type or a home location does not
    # resolve. A line is emitted when the procedure is completed, belongs to
    # this encounter, is the first copy of its id, carries a charge-set code
    # from CPT or HCPCS, has a valid serviced date, every diagnosis it uses
    # resolves to a billable ICD-10-CM condition, and has a finite
    # non-negative BigDecimal price from the injected price list. Anything
    # short of that is a ChargeProblem and not a line.
    #
    # Encounter diagnoses are listed in positive-integer rank order. A missing
    # rank sorts last; any other rank is invalid and the encounter list is
    # not a fallback. Procedure.reasonReference, in that order, supplies the
    # line's diagnosis pointers, and only when every reference resolves. A
    # procedure that names its own reasons never falls back to the encounter.
    # With no reasonReference the line points at the principal encounter
    # diagnosis, and only when every encounter diagnosis resolves to a
    # billable code. A later diagnosis is never promoted. One ICD-10-CM code
    # is one diagnosis, and a line cannot point at more than four.
    # verificationStatus refuted, entered-in-error, or unconfirmed is not
    # billable. confirmed, provisional, differential, and a missing status are.
    #
    # The serviced date is the calendar date written on performedDateTime, or
    # on performedPeriod.start when that is the instant present. The period
    # end is never the service date. A malformed date or dateTime is missing.
    # Rendering provider is a Practitioner NPI, by reference or by type. An
    # actor named as another resource, including Organization, does not count.
    # An actor that names no resource type still counts. Two Practitioner NPIs
    # on one procedure are ambiguous. Coverage is the reference Coverage/<id>
    # and the FHIR status, never the member identifier.
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
      CONDITION_VER_STATUS_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-ver-status"
      AUDIO_ONLY_MODIFIER_EXTENSION = "https://corvid.example/fhir/StructureDefinition/audio-only-modifier"
      # Confirmed, provisional, and differential may be billed. A missing
      # verificationStatus may too. Any other code, or a status not from
      # condition-ver-status, is not billable.
      BILLABLE_VERIFICATION = %w[confirmed provisional differential].freeze
      MAX_DIAGNOSIS_POINTERS = 4

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
      # 93 unless Coverage#audio_only_modifier names a non-blank payer code.
      # Blank or whitespace is no override. Video uses modifier 95, POS 10
      # at home (physical type ho) and POS 02 for any other place.
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
        DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/
        DATE_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/

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

        # Calendar date as written on a FHIR date or dateTime. The offset is
        # not applied, so a late evening in a negative offset stays that date.
        # A dateTime whose time or offset is malformed is not a date.
        def self.written_date(value)
          return nil unless acceptable_date?(value)

          Date.iso8601(value[0, 10])
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
            code = extension_value(extension, url)
            return code if code
          end
          nil
        end

        def extension_value(extension, url)
          return nil unless extension.is_a?(Hash) && extension["url"] == url

          text = extension["valueCode"]
          return nil unless text.is_a?(String)

          stripped = text.strip
          stripped.empty? ? nil : stripped
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

        def self.acceptable_date?(value)
          return false unless value.is_a?(String)
          return date_time?(value) if value.include?("T")

          DATE_ONLY.match?(value)
        end
        private_class_method :acceptable_date?

        def self.date_time?(value)
          DATE_TIME.match?(value) && !parsed_time(value).nil?
        end
        private_class_method :date_time?

        def self.parsed_time(value)
          return nil unless value.is_a?(String)

          Time.iso8601(value)
        rescue ArgumentError
          nil
        end
        private_class_method :parsed_time
      end

      # Claim diagnosis list. Encounter diagnoses are added first, in rank
      # order; procedure reasons append conditions that are not already
      # listed. One ICD-10-CM code is one Diagnosis. A reference that does
      # not resolve, or a condition that is not billable, blocks a line that
      # needed it. The encounter list is a fallback only when every entry
      # resolves to a billable code. A later diagnosis is never promoted
      # to principal.
      class DiagnosisList
        def initialize(conditions)
          @conditions = index_conditions(conditions)
          @items = []
          @by_id = {}
          @by_code = {}
          @blocked = {}
          @problems = []
          @principal_sequence = nil
          @fallback_blocked = false
        end

        attr_reader :items, :problems

        def block_fallback
          @fallback_blocked = true
        end

        def add_encounter(references)
          resolved = references.each_with_index.map do |reference, index|
            add_reference(reference, principal: index.zero?)
          end
          @fallback_blocked ||= resolved.empty? || resolved.any?(&:nil?)
          @principal_sequence = nil if @fallback_blocked
        end

        def sequences_for(references)
          resolved = references.map { |reference| add_reference(reference) }
          return nil if resolved.empty? || resolved.any?(&:nil?)

          resolved.uniq
        end

        def fallback_sequence
          return nil if @fallback_blocked

          @principal_sequence
        end

        private

        def add_reference(reference, principal: false)
          sequence = sequence_for(reference)
          @principal_sequence = sequence if principal
          sequence
        end

        def sequence_for(reference)
          id = FhirHash.reference_id(reference, "Condition")
          return missing_reference if id.nil?
          return @by_id[id] if @by_id.key?(id)
          return nil if @blocked.key?(id)

          remember(id)
        end

        def remember(id)
          condition = @conditions[id]
          code = icd10_code(condition)
          return block_condition(id, :diagnosis_unresolved) if code.nil?
          return block_condition(id, :diagnosis_not_billable) unless billable?(condition)

          @by_id[id] = @by_code[code] ||= append_code(code)
        end

        def append_code(code)
          sequence = @items.length + 1
          @items << Diagnosis.new(sequence: sequence, code: code)
          sequence
        end

        def block_condition(id, code)
          @blocked[id] = true
          @problems << ChargeProblem.new(code: code, reference: "Condition/#{id}")
          nil
        end

        def missing_reference
          @problems << ChargeProblem.new(code: :diagnosis_unresolved, reference: nil)
          nil
        end

        def billable?(condition)
          return false unless condition.is_a?(Hash)

          node = condition["verificationStatus"]
          return true if node.nil?

          BILLABLE_VERIFICATION.include?(FhirHash.coded(node, CONDITION_VER_STATUS_SYSTEM))
        end

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
        ranks = invalid_rank_problems
        @diagnoses.block_fallback if ranks.any?
        @diagnoses.add_encounter(ranked_condition_references)
        collect_lines
        rendering, extra = rendering_outcome
        result(
          lines: @lines,
          diagnoses: @diagnoses.items,
          problems: @diagnoses.problems + ranks + @problems + extra,
          rendering_provider_npi: rendering
        )
      end

      def collect_lines
        @lines = []
        @npis = []
        @line_refs = []
        @npi_conflicts = []
        @seen_procedure_ids = {}
        @procedures.each { |procedure| consider_procedure(procedure) }
      end

      def consider_procedure(raw)
        return add_problem(:procedure_not_in_encounter) unless raw.is_a?(Hash)

        procedure = FhirHash.new(raw)
        reference = procedure.reference("Procedure")
        return add_problem(:duplicate_procedure, reference) if duplicate_procedure?(procedure)
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
        @npis << line_npi(procedure)
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
        return reject_diagnosis(reference, :no_diagnosis) if sequences.nil?
        return reject_diagnosis(reference, :too_many_diagnoses) if sequences.length > MAX_DIAGNOSIS_POINTERS

        sequences
      end

      def reject_diagnosis(reference, code)
        add_problem(code, reference)
        nil
      end

      def fallback_diagnosis(reference)
        sequence = @diagnoses.fallback_sequence
        return [ sequence ] if sequence

        reject_diagnosis(reference, :no_diagnosis)
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

      # performedDateTime when that element is present, otherwise
      # performedPeriod.start. The period end is never the service date, and
      # a present but malformed instant does not fall through to the period.
      def serviced_date(procedure)
        FhirHash.written_date(serviced_instant(procedure))
      end

      def serviced_instant(procedure)
        procedure.dig("performedDateTime") || procedure.dig("performedPeriod", "start")
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

      # Practitioner NPIs only. An actor typed or referenced as another
      # resource, including Organization, does not count. An actor that names
      # no resource type still counts. Two different NPIs on one procedure are
      # ambiguous: the line is built and the NPI is nil.
      def line_npi(procedure)
        found = practitioner_npis(procedure).uniq
        conflict = found.length > 1
        @npi_conflicts << conflict
        conflict ? nil : found.first
      end

      def practitioner_npis(procedure)
        procedure.array("performer").filter_map { |performer| performer_npi(performer) }
      end

      def performer_npi(performer)
        actor = actor_hash(performer)
        return nil unless actor && practitioner_actor?(actor)

        FhirHash.npi(actor["identifier"])
      end

      def actor_hash(performer)
        return nil unless performer.is_a?(Hash)

        actor = performer["actor"]
        actor.is_a?(Hash) ? actor : nil
      end

      def practitioner_actor?(actor)
        !other_actor_type?(actor["type"]) && !other_actor_reference?(actor["reference"])
      end

      def other_actor_type?(type)
        type.is_a?(String) && !type.empty? && type != "Practitioner"
      end

      def other_actor_reference?(reference)
        return false unless reference.is_a?(String) && !reference.empty?

        !reference.start_with?("Practitioner/")
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
        problems << problem(:multiple_rendering_providers) if multiple_rendering_providers?
        problems
      end

      def multiple_rendering_providers?
        @npi_conflicts.any? || @npis.compact.uniq.length > 1
      end

      def missing_npi_problems
        @npis.each_with_index.filter_map do |npi, index|
          next if npi || @npi_conflicts[index]

          problem(:rendering_provider_missing, @line_refs[index])
        end
      end

      def duplicate_procedure?(procedure)
        id = procedure.string_at("id")
        return false if id.nil?
        return true if @seen_procedure_ids[id]

        @seen_procedure_ids[id] = true
        false
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
        when AMBULATORY_CLASS then ambulatory_modality
        when VIRTUAL_CLASS then virtual_modality
        end
      end

      def ambulatory_modality
        return nil if ambulatory_contradiction?

        modality_row(:in_person)
      end

      def ambulatory_contradiction?
        audio_only? || patient_home?
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
        usable_diagnosis_entries.sort_by { |entry, index| rank_key(entry, index) }
                                .map { |entry, _index| condition_reference(entry) }
      end

      def usable_diagnosis_entries
        diagnosis_entries.reject { |entry, _index| invalid_rank?(entry) }
      end

      def invalid_rank_problems
        diagnosis_entries.filter_map { |entry, _index| rank_problem(entry) }
      end

      def rank_problem(entry)
        return nil unless invalid_rank?(entry)

        problem(:diagnosis_rank_invalid, condition_reference_for(entry))
      end

      def invalid_rank?(entry)
        rank = entry["rank"]
        !rank.nil? && !positive_rank?(rank)
      end

      def positive_rank?(rank)
        rank.is_a?(Integer) && rank.positive?
      end

      def condition_reference(entry)
        FhirHash.dig_at(entry, "condition", "reference")
      end

      def condition_reference_for(entry)
        id = FhirHash.reference_id(condition_reference(entry), "Condition")
        return nil if id.nil?

        "Condition/#{id}"
      end

      def diagnosis_entries
        @encounter.array("diagnosis").each_with_index.filter_map do |entry, index|
          [ entry, index ] if entry.is_a?(Hash)
        end
      end

      def rank_key(entry, index)
        rank = entry["rank"]
        positive_rank?(rank) ? [ 0, rank, index ] : [ 1, 0, index ]
      end

      def read_coverage(raw)
        return nil unless raw.is_a?(Hash)

        fhir = FhirHash.new(raw)
        Coverage.new(
          payer_identifier: fhir.payor_identifier,
          identifier: fhir.reference("Coverage"),
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
