# frozen_string_literal: true

require "bigdecimal"
require "date"

module Corvid
  module Rcm
    # The predicates the scrub rules name. Rules are data; these are the code
    # the data points at.
    #
    # Every check has the same shape:
    #
    #   check(claim, params, context) -> [ { line_sequence:, values: {} }, ... ]
    #
    # An empty array means the claim passes. Each returned failure carries the
    # values that get interpolated into the rule's message, so the message text
    # stays in the data file and the specifics come from here.
    #
    # Checks never raise on missing data — a claim with nothing on it should
    # produce a pile of readable findings, not a stack trace.
    module ScrubChecks
      # ICD-10-CM code shape: a letter, a digit, a third alphanumeric character,
      # then an optional decimal point and up to four more. This is the only
      # thing about a diagnosis code that can be verified without the code
      # table itself — see `diagnosis_code_well_formed`.
      ICD10_CM_CODE = /\A[A-Z][0-9][0-9A-Z](\.[0-9A-Z]{1,4})?\z/

      # Identifiers are judged as written, not after stripping whatever is not a
      # digit: "abc1299999999" is not an NPI, however its digits check out.
      NPI_FORMAT = /\A\d{10}\z/
      # A 9-digit EIN, optionally written with its conventional hyphen.
      TAX_ID_FORMAT = /\A(\d{9}|\d{2}-\d{7})\z/

      module_function

      # -- helpers ------------------------------------------------------------

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def fail_with(values = {}, line_sequence: nil)
        [ { line_sequence: line_sequence, values: values } ]
      end

      # NPI check digit: Luhn over the 80840 prefix plus the first nine digits.
      def npi_check_digit_valid?(npi)
        body = npi.to_s.strip
        return false unless body.match?(NPI_FORMAT)

        sum = 0
        ("80840#{body[0, 9]}").chars.map(&:to_i).reverse.each_with_index do |digit, index|
          if index.even?
            doubled = digit * 2
            doubled -= 9 if doubled > 9
            sum += doubled
          else
            sum += digit
          end
        end
        ((10 - (sum % 10)) % 10) == body[9].to_i
      end

      def minutes_phrase(minutes)
        minutes.nil? ? "no documented time" : "#{minutes} minutes"
      end

      # Documented minutes as a whole number, or nil when they are absent or
      # not a number — either way the time does not support the code.
      def documented_minutes_of(item)
        Integer(item.documented_minutes.to_s.strip, 10)
      rescue ArgumentError, TypeError
        nil
      end

      # -- structural completeness --------------------------------------------

      def npi_valid(claim, params, _context)
        value = claim.public_send(params.fetch("field"))
        return [] if npi_check_digit_valid?(value)

        problem =
          if blank?(value)
            "missing"
          elsif !value.to_s.strip.match?(NPI_FORMAT)
            "not 10 digits (#{value.to_s.strip.inspect})"
          else
            "#{value.to_s.strip.inspect}, whose check digit does not validate"
          end
        fail_with({ problem: problem, label: params["label"] })
      end

      def tax_id_valid(claim, params, _context)
        value = claim.public_send(params.fetch("field"))
        return [] if value.to_s.strip.match?(TAX_ID_FORMAT)

        fail_with({ problem: blank?(value) ? "missing" : "not 9 digits (#{value.to_s.strip.inspect})" })
      end

      def taxonomy_valid(claim, params, _context)
        value = claim.public_send(params.fetch("field")).to_s.strip
        return [] if value.match?(/\A[A-Za-z0-9]{10}\z/)

        fail_with({ problem: value.empty? ? "missing" : "not a 10-character taxonomy code (#{value.inspect})" })
      end

      def coverage_field_present(claim, params, _context)
        return fail_with({}) if claim.coverage.nil?
        return [] unless blank?(claim.coverage.public_send(params.fetch("field")))

        fail_with({})
      end

      def coverage_active_on_service_date(claim, _params, _context)
        coverage = claim.coverage
        return [] if coverage.nil? # the payer-identifier rule reports this

        return fail_with({ problem: "not active (status #{coverage.status.to_s.inspect})" }) unless coverage.active?
        # An open end is ongoing coverage (FHIR Period); an unknown start is
        # not evidence the coverage had begun by the date of service.
        return fail_with({ problem: "unverifiable, because no coverage start date is recorded," }) if coverage.period_start.nil?

        Array(claim.items).flat_map do |item|
          date = item.serviced_date
          next [] if date.nil?

          if coverage.period_start && date < coverage.period_start
            fail_with({ problem: "not yet in force (began #{coverage.period_start})" }, line_sequence: item.sequence)
          elsif coverage.period_end && date > coverage.period_end
            fail_with({ problem: "terminated #{coverage.period_end}" }, line_sequence: item.sequence)
          else
            []
          end
        end
      end

      # The patient token is what every history rule matches on. A blank one
      # matches nothing, which would read as "no prior services".
      def patient_identifier_present(claim, _params, _context)
        blank?(claim.patient_identifier) ? fail_with({}) : []
      end

      PATIENT_DEMOGRAPHICS = [
        [ "family name", :patient_family_name, :subscriber_family_name ],
        [ "given name", :patient_given_name, :subscriber_given_name ],
        [ "date of birth", :patient_birth_date, :subscriber_birth_date ],
        [ "gender", :patient_gender, :subscriber_gender ]
      ].freeze

      # The 837P cannot carry a patient without name, birth date and gender;
      # intake rejects it. Names the missing fields only.
      def patient_demographics_present(claim, _params, _context)
        missing = PATIENT_DEMOGRAPHICS.filter_map { |label, field, _| label if blank?(claim.public_send(field)) }
        return [] if missing.empty?

        fail_with({ missing: missing.join(", ") })
      end

      # Only meaningful when the patient IS the subscriber. A field missing on
      # the claim side is `patient_demographics_present`'s finding; a field the
      # coverage does not record cannot be matched at all, and absence never
      # verifies, so it fails here.
      #
      # Messages name the fields, never the values: a finding is rendered and
      # may be logged, and names and birth dates are PHI (ADR 0003).
      def subscriber_demographics_match(claim, _params, _context)
        coverage = claim.coverage
        return [] if coverage.nil? || !coverage.self_relationship?

        mismatched = []
        unrecorded = []
        PATIENT_DEMOGRAPHICS.each do |label, claim_field, coverage_field|
          claim_value = claim.public_send(claim_field)
          coverage_value = coverage.public_send(coverage_field)
          next if blank?(claim_value)

          if blank?(coverage_value)
            unrecorded << label
          elsif claim_value.to_s.strip.upcase != coverage_value.to_s.strip.upcase
            mismatched << label
          end
        end

        problems = []
        problems << "#{mismatched.join(', ')} differ" if mismatched.any?
        problems << "#{unrecorded.join(', ')} not recorded on the coverage, so cannot be matched" if unrecorded.any?
        return [] if problems.empty?

        fail_with({ problem: problems.join("; ") })
      end

      # -- service lines -------------------------------------------------------

      def service_lines_present(claim, _params, _context)
        Array(claim.items).empty? ? fail_with({}) : []
      end

      # Each line has to carry a procedure code, a date of service and a usable
      # billed amount. The line-scoped rules skip what they cannot see, so a
      # line missing any of these blocks here instead of passing by omission.
      def service_line_complete(claim, _params, _context)
        Array(claim.items).flat_map do |item|
          problems = []
          problems << "no procedure code" if blank?(item.procedure_code)
          problems << "no date of service" if item.serviced_date.nil?
          amount_problem = billed_amount_problem(item)
          problems << amount_problem if amount_problem
          next [] if problems.empty?

          fail_with({ problem: "Line #{item.sequence} has #{problems.join(', ')}." }, line_sequence: item.sequence)
        end
      end

      def billed_amount_problem(item)
        return "an unparseable billed amount (#{item.amount_error})" unless blank?(item.amount_error)
        return "no billed amount" if blank?(item.billed_amount)

        amount = BigDecimal(item.billed_amount.to_s)
        return "a billed amount that is not a finite number" unless amount.finite?
        return "a billed amount that is not positive" unless amount.positive?
        return "a billed amount with fractions of a cent" unless amount.round(2) == amount

        nil
      rescue ArgumentError, TypeError
        "an unparseable billed amount"
      end

      def diagnosis_pointers_resolve(claim, _params, _context)
        available = Array(claim.diagnoses).map(&:sequence)

        Array(claim.items).flat_map do |item|
          pointers = Array(item.diagnosis_sequences)
          if pointers.empty?
            fail_with({ problem: "Line #{item.sequence} (#{item.procedure_code}) points at no diagnosis." },
                      line_sequence: item.sequence)
          else
            dangling = pointers - available
            next [] if dangling.empty?

            fail_with({ problem: "Line #{item.sequence} (#{item.procedure_code}) points at diagnosis #{dangling.join(', ')}, which is not on the claim." },
                      line_sequence: item.sequence)
          end
        end
      end

      # -- place of service / telehealth --------------------------------------

      def place_of_service_matches_modality(claim, params, _context)
        expectations = params.fetch("expectations")
        payer_audio_only_modifier = claim.coverage&.audio_only_modifier

        Array(claim.items).flat_map do |item|
          if item.encounter_modality.nil?
            next fail_with({ problem: "Line #{item.sequence} (#{item.procedure_code}) does not record how the encounter happened, so its place of service cannot be verified." },
                           line_sequence: item.sequence)
          end

          # An unrecognised modality fails exactly as closed as a missing one.
          # A typo or an unmapped modality is not evidence that the place of
          # service is right — it is evidence that nobody can tell, and this
          # rule exists precisely because a POS/modifier mismatch denies the
          # whole telehealth book rather than one claim.
          expectation = expectations[item.encounter_modality.to_s]
          if expectation.nil?
            next fail_with({ problem: "Line #{item.sequence} (#{item.procedure_code}) records the encounter modality #{item.encounter_modality.to_s.inspect}, which this ruleset does not recognise, so its place of service cannot be verified." },
                           line_sequence: item.sequence)
          end

          allowed_pos = Array(expectation["place_of_service"])
          required = Array(expectation["required_modifiers"])
          # Audio-only modifier policy is payer-specific; the coverage record
          # wins over the default when the tenant has confirmed it.
          if item.encounter_modality == :audio_only && !blank?(payer_audio_only_modifier)
            required = [ payer_audio_only_modifier.to_s ]
          end
          forbidden = Array(expectation["forbidden_modifiers"]) - required

          problems = []
          unless allowed_pos.include?(item.place_of_service.to_s)
            problems << "place of service #{item.place_of_service.to_s.inspect} (expected #{allowed_pos.map(&:inspect).join(' or ')})"
          end
          missing = required.reject { |mod| item.modifier?(mod) }
          problems << "missing modifier #{missing.map(&:inspect).join(', ')}" if missing.any?
          present_forbidden = forbidden.select { |mod| item.modifier?(mod) }
          problems << "modifier #{present_forbidden.map(&:inspect).join(', ')} which does not belong on it" if present_forbidden.any?

          next [] if problems.empty?

          fail_with({ problem: "Line #{item.sequence} (#{item.procedure_code}) is documented as #{expectation['description']} but carries #{problems.join(' and ')}." },
                    line_sequence: item.sequence)
        end
      end

      def audio_only_policy_configured(claim, params, _context)
        return [] unless Array(claim.items).any? { |item| item.encounter_modality == :audio_only }
        return [] unless blank?(claim.coverage&.audio_only_modifier)

        fail_with({ default_modifier: params.fetch("default_modifier", "93") })
      end

      # -- time-supported coding ----------------------------------------------

      def minimum_documented_minutes(claim, params, _context)
        code = params.fetch("procedure_code")
        minimum = params.fetch("minimum_minutes")

        Array(claim.items).select { |item| item.procedure_code == code }.flat_map do |item|
          minutes = documented_minutes_of(item)
          next [] if minutes && minutes >= minimum

          fail_with({ code: code, documented: minutes_phrase(minutes), minimum: minimum },
                    line_sequence: item.sequence)
        end
      end

      def documented_minutes_in_range(claim, params, _context)
        code = params.fetch("procedure_code")
        minimum = params.fetch("minimum_minutes")
        maximum = params.fetch("maximum_minutes")

        Array(claim.items).select { |item| item.procedure_code == code }.flat_map do |item|
          minutes = documented_minutes_of(item)
          next [] if minutes && minutes >= minimum && minutes <= maximum

          fail_with({ code: code, documented: minutes_phrase(minutes), minimum: minimum,
                      maximum: maximum, above_range_code: params["above_range_code"] },
                    line_sequence: item.sequence)
        end
      end

      def repeat_service_within_months(claim, params, context)
        code = params.fetch("procedure_code")
        months = params.fetch("months")
        history = context.history
        return [] if history.nil?

        Array(claim.items).select { |item| item.procedure_code == code }.flat_map do |item|
          date = item.serviced_date || context.as_of
          priors = history.services_for(
            patient_identifier: claim.patient_identifier,
            procedure_code: code,
            rendering_provider_npi: params["same_rendering_provider"] ? claim.rendering_provider_npi : nil,
            on_or_after: date << months
          ).reject { |prior| prior.serviced_date && prior.serviced_date > date }
          next [] if priors.empty?

          fail_with({ code: code, months: months,
                      prior_dates: priors.map(&:serviced_date).compact.sort.join(", ") },
                    line_sequence: item.sequence)
        end
      end

      # -- diagnosis coding ----------------------------------------------------

      # The only diagnosis property that can be verified from the code alone,
      # with no ICD-10-CM table in hand. A malformed code is not a judgement
      # call: it never adjudicates anywhere, so this one blocks.
      def diagnosis_code_well_formed(claim, _params, _context)
        Array(claim.diagnoses).flat_map do |diagnosis|
          code = diagnosis.code.to_s.strip.upcase
          next [] if code.match?(ICD10_CM_CODE)

          problem =
            if code.empty?
              "A diagnosis on the claim carries no code at all."
            else
              "Diagnosis #{code.inspect} is not a well-formed ICD-10-CM code."
            end
          fail_with({ problem: problem })
        end
      end

      # Whether a code is a non-billable header is a property of the ICD-10-CM
      # table, not of the code's shape, and Phase 0 does not carry that table.
      # Both inputs here are therefore best-effort DATA:
      #
      #   * `nonbillable_codes` — a curated list of subcategory headers, and
      #   * `billable_category_codes` — the three-character rubrics that ARE
      #     valid leaf codes, because "three characters" does not imply
      #     "header" (F70 and F23 are three characters and perfectly billable).
      #
      # Being best-effort is exactly why the rule that points at this check
      # WARNS. A hand-maintained list that blocks is a list that eventually
      # refuses to transmit one of the clinic's own legitimate claims, silently
      # and with no payer response to notice it by.
      def nonbillable_diagnosis_codes(claim, params, _context)
        chapter = params["chapter"]
        headers = Array(params["nonbillable_codes"]).map { |code| code.to_s.upcase }
        billable_rubrics = Array(params["billable_category_codes"]).map { |code| code.to_s.upcase }

        Array(claim.diagnoses).flat_map do |diagnosis|
          code = diagnosis.code.to_s.strip.upcase
          next [] unless chapter.nil? || diagnosis.chapter_letter.to_s.upcase == chapter.to_s.upcase

          if diagnosis.category_header? && !billable_rubrics.include?(code)
            fail_with({ problem: "Diagnosis #{code} is a three-character category rubric that is not on the list of billable rubrics, so it is probably a header with subcategories." })
          elsif headers.include?(code)
            fail_with({ problem: "Diagnosis #{code} is a known subcategory header with billable children, so it is probably not billable itself." })
          else
            []
          end
        end
      end

      # -- filing window and duplicates ---------------------------------------

      def timely_filing_elapsed(claim, params, context)
        fraction = params.fetch("at_least_fraction", 0.5)

        filing_lines(claim, context).flat_map do |item, window, deadline|
          next [] if context.as_of > deadline # the expiry rule owns this

          elapsed_days = (context.as_of - item.serviced_date).to_i
          next [] if elapsed_days < (window * fraction)

          fail_with({ code: item.procedure_code, window: window,
                      serviced_date: item.serviced_date,
                      elapsed: "#{(elapsed_days * 100 / window)}%",
                      remaining: (deadline - context.as_of).to_i },
                    line_sequence: item.sequence)
        end
      end

      # The other filing rules are silent without a window, so this is the one
      # that says so: an unknown window is not evidence the claim is in time.
      def timely_filing_window_configured(claim, _params, _context)
        window = claim.coverage&.timely_filing_days
        return [] if claim.coverage.nil? # the payer-identifier rule reports this
        return [] if window && window.to_i.positive?

        fail_with({})
      end

      def timely_filing_expired(claim, _params, context)
        filing_lines(claim, context).flat_map do |item, window, deadline|
          next [] unless context.as_of > deadline

          fail_with({ code: item.procedure_code, window: window,
                      serviced_date: item.serviced_date, deadline: deadline },
                    line_sequence: item.sequence)
        end
      end

      # A duplicate is the same patient, same date of service and same procedure
      # code with nothing to tell the two apart — and it is worth catching on
      # BOTH sides of the claim boundary:
      #
      #   * two lines on THIS claim, which the payer will deny CO-18 just as
      #     readily as it denies a resubmission; and
      #   * a line matching something already submitted.
      #
      # Modifiers are what tell two same-day services apart. A line carrying a
      # distinct-service modifier the other one does not carry is exactly the
      # escape hatch the remedy text promises, so it has to actually pass —
      # otherwise a clinic with two legitimate sessions in a day can never
      # bill the second one.
      def duplicate_service(claim, params, context)
        distinguishing = Array(params["distinguishing_modifiers"]).map { |mod| mod.to_s.upcase }
        dated_items = Array(claim.items).reject { |item| item.serviced_date.nil? }

        intra_claim_duplicates(dated_items, distinguishing) +
          history_duplicates(claim, dated_items, distinguishing, context)
      end

      # Two lines on the same claim, same code, same day, nothing distinguishing
      # them. Reported on the later line — the earlier one is the keeper.
      def intra_claim_duplicates(dated_items, distinguishing)
        dated_items.each_with_index.flat_map do |item, index|
          earlier = dated_items[0...index].find do |candidate|
            candidate.procedure_code == item.procedure_code &&
              candidate.serviced_date == item.serviced_date &&
              !modifiers_distinguish?(item.modifiers, candidate.modifiers, distinguishing)
          end
          next [] if earlier.nil?

          fail_with({ problem: "Line #{item.sequence} (#{item.procedure_code} on #{item.serviced_date}) repeats line #{earlier.sequence} on this same claim, with no distinct-service modifier to tell them apart." },
                    line_sequence: item.sequence)
        end
      end

      # nil history is UNKNOWN, not "none" — the nil/[] rule the adapters use.
      # Nobody can say the claim was not already sent, so it blocks; a caller
      # that knows there is nothing passes `ClaimHistory.empty`.
      def history_duplicates(claim, dated_items, distinguishing, context)
        history = context.history
        if history.nil?
          return fail_with({ problem: "No claim history was supplied, so Corvid cannot tell whether these services were already submitted." })
        end

        dated_items.flat_map do |item|
          priors = history.duplicates_of(
            patient_identifier: claim.patient_identifier,
            procedure_code: item.procedure_code,
            serviced_date: item.serviced_date
          ).reject { |prior| modifiers_distinguish?(item.modifiers, prior.modifiers, distinguishing) }
          next [] if priors.empty?

          references = priors.map { |prior| prior.claim_identifier || "an earlier claim" }.uniq
          fail_with({ problem: "Line #{item.sequence} (#{item.procedure_code} on #{item.serviced_date}) was already submitted for this patient on #{references.join(', ')}." },
                    line_sequence: item.sequence)
        end
      end

      # Two same-day services are distinguished when one of them carries a
      # distinct-service modifier the other does not. Both carrying the same
      # modifier distinguishes nothing — that is still two identical lines.
      def modifiers_distinguish?(left, right, distinguishing)
        return false if distinguishing.empty?

        left_set = Array(left).map { |mod| mod.to_s.upcase }
        right_set = Array(right).map { |mod| mod.to_s.upcase }
        ((left_set - right_set) | (right_set - left_set)).any? { |mod| distinguishing.include?(mod) }
      end

      # Lines that can be judged against a filing window at all: the payer's
      # window has to be configured and the line has to have a date of service.
      # An unconfigured window yields no lines here; `timely_filing_window_configured`
      # is the rule that reports the gap.
      def filing_lines(claim, context)
        window = claim.coverage&.timely_filing_days
        return [] if window.nil? || window.to_i <= 0

        window = window.to_i
        Array(claim.items).filter_map do |item|
          next if item.serviced_date.nil?

          [ item, window, item.serviced_date + window ]
        end
      end
    end
  end
end
