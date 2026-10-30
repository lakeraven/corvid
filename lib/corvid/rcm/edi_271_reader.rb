# frozen_string_literal: true

require "bigdecimal"
require "date"

require_relative "eligibility"

module Corvid
  module Rcm
    # Minimal reader for the X12 271 Eligibility Benefit Response.
    #
    # It understands the segments a coverage answer is actually made of —
    # ISA delimiters, ST/SE, HL, NM1 (payer at the information source),
    # REF*6P and REF*1L, DTP plan dates, EB, and AAA — and ignores the rest
    # rather than guessing. BHT is accepted and not mapped: BHT03 is a trace
    # that can carry a patient-control number, and `as_of` comes from the
    # caller's clock, not from the file. Demographic elements (NM103–NM107
    # names, DMG) are not copied onto the result. The member identifier on
    # NM109 is not copied either: the caller already has it, and it must not
    # reappear in a reference or an exception (ADR 0003).
    #
    # HL level codes are 20 information source, 21 receiver, 22 subscriber,
    # and 23 dependent. Plan benefits and the group REF come from the
    # subscriber loop, unless a dependent loop is present — then they come
    # from the dependent loop only, and subscriber-loop EBs are ignored.
    # The payer identifier still comes from the information-source NM1.
    # More than one information-source loop, more than one subscriber
    # loop, or more than one dependent loop in the transaction is
    # ambiguous: the reader returns no plan, rather than picking one and
    # calling the patient active. AAA at any level is still reported.
    #
    # Plan coverage dates are DTP segments before the first EB of a loop.
    # `coverage_start` and `coverage_end` are the most restrictive bounds:
    # the latest start and the earliest end. When a dependent loop is
    # selected, those bounds run across the subscriber loop and the
    # dependent loop together; each loop only contributes DTPs from before
    # its own first EB. A year-9999 value is open-ended and never overrides
    # a real bound. Start qualifiers are 291 (plan), 307 (eligibility),
    # 346 (plan begin), and 356 (eligibility begin). End qualifiers are
    # 347 (plan end), 357 (eligibility end), and 540 (policy expiration).
    # RD8 on any of those is a start-end range. A range whose start is
    # after its end is a malformed file, as are restrictive bounds whose
    # start is after their end. D8 on 307 is the eligibility day. It is
    # stored as `eligibility_date`, and it pins both restrictive bounds to
    # that day when the day lies in the other plan bounds (a missing bound
    # is open, so a lone D8 307 is both bounds). A day outside those bounds
    # stays on `eligibility_date` and does not invert the window. Two
    # different eligibility days are malformed: the bounds they would form
    # start after they end. D8 on another start qualifier is a start; D8
    # on an end qualifier is an end. Every other qualifier, including 472,
    # is ignored. Each subscriber or selected dependent loop that stated
    # plan dates other than D8 307 contributes one `EligibilityWindow`:
    # that loop's earliest start and latest end, with a year-9999 side
    # left nil. A present plan-date value that is not a real day or a
    # year-9999 placeholder is a malformed file. Segments after the first
    # EB (2110) do not change plan dates or the group REF. The plan name
    # is EB05 on a coverage EB (EB01 1 or 6) only; EB04 is an insurance
    # type code. The group number is REF*6P, or REF*1L when 6P is absent;
    # 6P wins when both are present.
    #
    # A file that is not a 271 transaction raises `MalformedError` with a fixed
    # message. The message is a constant so a parse failure cannot echo a
    # member identifier, a patient identifier, or the file body. An empty but
    # well-formed 271 is not a parse failure: it has no benefits and no
    # rejects, and the caller maps that to `:undetermined`.
    class Edi271Reader
      class MalformedError < StandardError; end

      Result = Data.define(:plans, :errors, :raw_reference)

      MALFORMED_MESSAGE = "malformed 271 eligibility response"
      ISA_LENGTH = 106

      DEFAULT_DELIMITERS = {
        segment: "~",
        element: "*",
        repetition: "^",
        component: ">"
      }.freeze

      # AAA03 reject reason codes from the 005010X279 271. A code that is not
      # in this table is still an error — the description is generic and the
      # outcome stays undetermined. Descriptions are the short X12 reason
      # names, not advice about a particular member.
      AAA_REJECT_REASONS = {
        "04" => "Authorized Quantity Exceeded",
        "15" => "Required application data missing",
        "33" => "Input Errors",
        "35" => "Out of Network",
        "41" => "Authorization/Access Restrictions",
        "42" => "Unable to Respond at Current Time",
        "43" => "Invalid/Missing Provider Identification",
        "44" => "Invalid/Missing Provider Name",
        "45" => "Invalid/Missing Provider Specialty",
        "46" => "Invalid/Missing Provider Phone Number",
        "47" => "Invalid/Missing Provider State",
        "48" => "Invalid/Missing Referring Provider Identification Number",
        "49" => "Provider is Not Primary Care Physician",
        "50" => "Provider Ineligible for Inquiries",
        "51" => "Provider Not on File",
        "52" => "Service Dates Not Within Provider Plan Enrollment",
        "53" => "Inquired Benefit Inconsistent with Provider Type",
        "54" => "Inappropriate Product/Service ID Qualifier",
        "55" => "Inappropriate Product/Service ID",
        "56" => "Inappropriate Date",
        "57" => "Invalid/Missing Date(s) of Service",
        "58" => "Invalid/Missing Date of Birth",
        "60" => "Date of Birth Follows Date(s) of Service",
        "61" => "Date of Death Precedes Date(s) of Service",
        "62" => "Date of Service Not Within Allowable Inquiry Period",
        "63" => "Date of Service in Future",
        "64" => "Invalid/Missing Patient ID",
        "65" => "Invalid/Missing Patient Name",
        "66" => "Invalid/Missing Patient Gender Code",
        "67" => "Patient Not Found",
        "68" => "Duplicate Patient ID Number",
        "69" => "Inconsistent with Patient's Age",
        "70" => "Inconsistent with Patient's Gender",
        "71" => "Patient Birth Date Does Not Match That for the Patient on the Database",
        "72" => "Invalid/Missing Subscriber/Insured ID",
        "73" => "Invalid/Missing Subscriber/Insured Name",
        "74" => "Invalid/Missing Subscriber/Insured Gender Code",
        "75" => "Subscriber/Insured Not Found",
        "76" => "Duplicate Subscriber/Insured ID Number",
        "77" => "Subscriber Found, Patient Not Found",
        "78" => "Subscriber/Insured Not in Group/Plan Identified",
        "79" => "Invalid Participant Identification",
        "80" => "No Response received - Transaction Terminated",
        "97" => "Invalid or Missing Provider Address",
        "T4" => "Payer Name or Identifier Missing"
      }.freeze

      UNMAPPED_REJECT_DESCRIPTION = "Unmapped eligibility reject reason"
      REJECTED_WITHOUT_REASON = "Eligibility request rejected"

      # Plan-level DTP01 qualifiers. 348/349 are benefit dates and are not
      # in this list. 472 (service) and every other qualifier are ignored.
      # 307 is also a start qualifier; D8 on 307 alone sets both bounds.
      START_DATE_QUALIFIERS = %w[291 307 346 356].freeze
      END_DATE_QUALIFIERS = %w[347 357 540].freeze
      ELIGIBILITY_DATE_QUALIFIER = "307"
      PLAN_DATE_QUALIFIERS = (START_DATE_QUALIFIERS | END_DATE_QUALIFIERS).freeze
      DATE_FORMAT = "D8"
      DATE_RANGE_FORMAT = "RD8"
      PLAN_DAY = /\A\d{8}\z/
      PLAN_DAY_RANGE = /\A(\d{8})-(\d{8})\z/
      OPEN_ENDED_YEAR = "9999"

      PAYER_ENTITY = "PR"
      PAYER_ID_QUALIFIER = "PI"
      INFORMATION_SOURCE_LEVEL = "20"
      INFORMATION_RECEIVER_LEVEL = "21"
      SUBSCRIBER_LEVEL = "22"
      DEPENDENT_LEVEL = "23"
      GROUP_NUMBER_QUALIFIER = "6P"
      GROUP_OR_POLICY_QUALIFIER = "1L"
      TRANSACTION_SET = "271"

      # Benefit, group, and coverage-date state for one HL 22 or HL 23 loop.
      # Mutable only while the transaction is being read.
      class PlanLoop
        attr_reader :benefits, :coverage_start, :coverage_end, :eligibility_date
        attr_accessor :plan_name

        def initialize
          @benefits = []
          @plan_name = nil
          @group_6p = nil
          @group_1l = nil
          @coverage_start = nil
          @coverage_end = nil
          @eligibility_date = nil
          @stated_start = nil
          @stated_end = nil
          @stated_plan_dates = false
          @seen_eb = false
        end

        def seen_eb?
          @seen_eb
        end

        def mark_eb
          @seen_eb = true
        end

        def add_benefit(benefit)
          @benefits << benefit
        end

        # REF*6P is the group number when present; REF*1L is the fallback.
        # The first value of each qualifier is the one that is kept.
        def note_group(qualifier, value)
          case qualifier
          when GROUP_NUMBER_QUALIFIER
            @group_6p ||= value
          when GROUP_OR_POLICY_QUALIFIER
            @group_1l ||= value
          end
        end

        def group_number
          @group_6p || @group_1l
        end

        # Latest real start. Nil is an open-ended placeholder and does not
        # replace a date already recorded.
        def note_start(date)
          return if date.nil?
          return if @coverage_start && @coverage_start >= date

          @coverage_start = date
        end

        # Earliest real end. Nil is an open-ended placeholder and does not
        # replace a date already recorded.
        def note_end(date)
          return if date.nil?
          return if @coverage_end && @coverage_end <= date

          @coverage_end = date
        end

        # Earliest start the loop stated, excluding a D8 eligibility day.
        # Nil is an open-ended placeholder and does not replace a real day.
        def note_stated_start(date)
          @stated_plan_dates = true
          return if date.nil?
          return if @stated_start && @stated_start <= date

          @stated_start = date
        end

        # Latest end the loop stated, excluding a D8 eligibility day.
        # Nil is an open-ended placeholder and does not replace a real day.
        def note_stated_end(date)
          @stated_plan_dates = true
          return if date.nil?
          return if @stated_end && @stated_end >= date

          @stated_end = date
        end

        def note_plan_start(date)
          note_start(date)
          note_stated_start(date)
        end

        def note_plan_end(date)
          note_end(date)
          note_stated_end(date)
        end

        # An RD8 range is both a restrictive bound and a stated bound.
        def note_range(start_on, end_on)
          note_plan_start(start_on)
          note_plan_end(end_on)
        end

        # A second, different D8 307 day in this loop. Nil does not conflict.
        def conflicting_eligibility_date?(date)
          !date.nil? && @eligibility_date && @eligibility_date != date
        end

        def note_eligibility_date(date)
          return if date.nil?

          @eligibility_date = date
        end

        # Nil when this loop stated no plan dates other than a D8 307 day.
        def stated_window
          return nil unless @stated_plan_dates

          EligibilityWindow.new(start_date: @stated_start, end_date: @stated_end)
        end
      end
      private_constant :PlanLoop

      def self.read(path)
        new(File.binread(path)).parse
      rescue SystemCallError
        # `cause: nil` so the path, which may contain a member identifier,
        # cannot ride out on the chained exception.
        raise MalformedError, MALFORMED_MESSAGE, cause: nil
      end

      def self.parse(source)
        new(source).parse
      end

      def initialize(source)
        @source = utf8(source)
        @delimiters = detect_delimiters(@source)
      end

      def parse
        prepare
        segments = split_segments(@source)
        malformed! if segments.empty?

        segments.each_with_index { |elements, index| consume(elements, index) }
        finish
      end

      private

      # A string already tagged UTF-8 is not transcoded: invalid bytes are a
      # malformed file, not an ArgumentError from `encode`. ASCII-8BIT (what
      # `File.binread` returns) is reinterpreted as UTF-8, because `encode`
      # would reject a non-ASCII byte that is already valid UTF-8. Any other
      # encoding is converted. `valid_encoding?` then rejects bytes that are
      # not UTF-8.
      def utf8(source)
        converted = to_utf8(source.to_s)
        malformed! unless converted.valid_encoding?

        converted
      end

      def to_utf8(text)
        return text if text.encoding == Encoding::UTF_8
        return reinterpret_as_utf8(text) if text.encoding == Encoding::ASCII_8BIT

        text.encode(Encoding::UTF_8)
      rescue EncodingError, ArgumentError
        malformed!
      end

      # Dup so `force_encoding` does not change the caller's string.
      def reinterpret_as_utf8(text)
        text.dup.force_encoding(Encoding::UTF_8)
      end

      def detect_delimiters(source)
        return DEFAULT_DELIMITERS unless source.start_with?("ISA")

        isa_delimiters(source) || malformed!
      end

      # The ISA header is a fixed 106-character prefix. Element, repetition,
      # component, and segment separators are whatever that prefix says they
      # are; the 835 reader hard-codes the same defaults this falls back to
      # when there is no ISA.
      def isa_delimiters(source)
        return nil unless source.length >= ISA_LENGTH

        isa = source[0, ISA_LENGTH]
        element = isa[3]
        segment = isa[-1]
        elements = isa[0..-2].split(element.to_s, -1)
        return nil unless elements[0] == "ISA" && elements.length >= 17

        separators = [ element, segment, elements[11].to_s, elements[16].to_s ]
        return nil unless separators.all? { |char| char.to_s.length == 1 }
        return nil if separators.uniq.length != separators.length

        {
          segment: separators[1],
          element: separators[0],
          repetition: separators[2],
          component: separators[3]
        }.freeze
      end

      def split_segments(source)
        source.split(@delimiters.fetch(:segment)).filter_map do |raw|
          segment = raw.strip
          next if segment.empty?

          segment.split(@delimiters.fetch(:element), -1)
        end
      end

      def prepare
        @errors = []
        @payer_identifier = nil
        @subscriber_loops = []
        @dependent_loops = []
        @information_source_count = 0
        @current_loop = nil
        @hl_level = nil
        @saw_st = false
        @transaction_271 = false
        @open = false
        @closed = false
        @st_index = nil
        @st_control = nil
      end

      def consume(elements, index)
        case elements[0]
        when "ST" then open_transaction(elements, index)
        when "SE" then close_transaction(elements, index)
        else consume_body(elements) if @open
        end
      end

      def open_transaction(elements, index)
        malformed! if @saw_st

        @saw_st = true
        @st_index = index
        @st_control = element(elements, 2)
        return unless element(elements, 1) == TRANSACTION_SET

        @transaction_271 = true
        @open = true
      end

      # SE01 counts ST through SE inclusive. A transaction that does not close,
      # or that closes on a different control number, is truncated.
      def close_transaction(elements, index)
        malformed! unless @transaction_271 && @open

        actual = index - @st_index + 1
        malformed! unless element(elements, 1) == actual.to_s
        malformed! unless element(elements, 2) == @st_control.to_s

        @open = false
        @closed = true
      end

      def consume_body(elements)
        case elements[0]
        when "HL" then consume_hl(elements)
        when "NM1" then consume_nm1(elements)
        when "REF" then consume_ref(elements)
        when "DTP" then consume_dtp(elements)
        when "EB" then consume_eb(elements)
        when "AAA" then consume_aaa(elements)
        end
      end

      def consume_hl(elements)
        @hl_level = element(elements, 3)
        @current_loop = loop_for_level(@hl_level)
      end

      # 20 and 21 are not plan loops. Each 22 or 23 starts a new loop so a
      # later EB cannot see the previous loop's dates or benefits. More
      # than one information source is ambiguous (see `ambiguous_loops?`).
      def loop_for_level(level)
        case level
        when SUBSCRIBER_LEVEL then open_loop(@subscriber_loops)
        when DEPENDENT_LEVEL then open_loop(@dependent_loops)
        when INFORMATION_SOURCE_LEVEL then count_information_source
        when INFORMATION_RECEIVER_LEVEL then nil
        end
      end

      def count_information_source
        @information_source_count += 1
        nil
      end

      def open_loop(loops)
        loops << PlanLoop.new
        loops.last
      end

      # 2100A payer, on the information-source loop (HL 20). NM109 is the
      # payer identifier (PI). The organization name in NM103 is not kept.
      # Subscriber and dependent NM1 names and member identifiers are not
      # read (ADR 0003). A dependent's plan still uses this payer; it does
      # not use the subscriber NM1.
      def consume_nm1(elements)
        return unless element(elements, 1) == PAYER_ENTITY
        return unless element(elements, 8) == PAYER_ID_QUALIFIER
        return if @hl_level && @hl_level != INFORMATION_SOURCE_LEVEL

        identifier = element(elements, 9)
        return if identifier.empty?

        @payer_identifier ||= identifier
      end

      # Group REF after the first EB is benefit level (2110) and does not
      # change the plan.
      def consume_ref(elements)
        return if @current_loop.nil? || @current_loop.seen_eb?

        qualifier = element(elements, 1)
        value = element(elements, 2)
        return if value.empty?

        @current_loop.note_group(qualifier, value)
      end

      # Only a DTP before the first EB of this subscriber or dependent loop
      # can set plan bounds. Benefit-level dates (2110) follow an EB and
      # are not validated.
      def consume_dtp(elements)
        plan_loop = @current_loop
        return if plan_loop.nil? || plan_loop.seen_eb?

        raw = element(elements, 3)
        return if raw.empty?

        apply_plan_date(plan_loop, element(elements, 1), element(elements, 2), raw)
      end

      def apply_plan_date(plan_loop, qualifier, format, raw)
        return unless PLAN_DATE_QUALIFIERS.include?(qualifier)

        case format
        when DATE_RANGE_FORMAT then note_date_range(plan_loop, raw)
        when DATE_FORMAT then note_single_date(plan_loop, qualifier, raw)
        end
      end

      def note_date_range(plan_loop, raw)
        start_on, end_on = plan_date_range(raw)
        malformed! if dates_reversed?(start_on, end_on)

        plan_loop.note_range(start_on, end_on)
      end

      # D8 on 307 is the eligibility day. It is not a stated-window bound.
      # Whether it also pins the restrictive window is decided once every
      # plan date has been seen. D8 on any other start qualifier is a
      # start; D8 on an end qualifier is an end.
      def note_single_date(plan_loop, qualifier, raw)
        date = plan_date(raw)
        if qualifier == ELIGIBILITY_DATE_QUALIFIER
          note_eligibility_day(plan_loop, date)
        elsif END_DATE_QUALIFIERS.include?(qualifier)
          plan_loop.note_plan_end(date)
        else
          plan_loop.note_plan_start(date)
        end
      end

      def note_eligibility_day(plan_loop, date)
        malformed! if plan_loop.conflicting_eligibility_date?(date)

        plan_loop.note_eligibility_date(date)
      end

      def dates_reversed?(start_on, end_on)
        start_on && end_on && start_on > end_on
      end

      def plan_date_range(raw)
        halves = PLAN_DAY_RANGE.match(raw.to_s.strip)
        malformed! if halves.nil?

        [ plan_date(halves[1]), plan_date(halves[2]) ]
      end

      # CCYYMMDD. Year 9999 is an open-ended placeholder (nil) and is not
      # run through the calendar. Any other present value that is not a
      # real day is a malformed 271. `EligibilityPlan.coverage_date` stays
      # nil for those values; this parse is what tells them apart.
      def plan_date(raw)
        text = raw.to_s.strip
        malformed! unless text.match?(PLAN_DAY)
        return nil if text.start_with?(OPEN_ENDED_YEAR)

        Date.strptime(text, "%Y%m%d")
      rescue Date::Error
        malformed!
      end

      # EB03 repeats with the ISA repetition separator. One benefit per
      # service type code; a segment with none still counts toward outcome
      # when the asked service types include 30. An EB outside a subscriber
      # or dependent loop is not a plan benefit.
      def consume_eb(elements)
        code = element(elements, 1)
        malformed! if code.empty?
        return if @current_loop.nil?

        plan_loop = @current_loop
        plan_loop.mark_eb
        remember_plan_name(plan_loop, elements, code)
        service_type_codes(element(elements, 3)).each do |service_type_code|
          plan_loop.add_benefit(benefit(elements, code, service_type_code))
        end
      end

      def benefit(elements, code, service_type_code)
        EligibilityBenefit.new(
          service_type_code: service_type_code,
          code: code,
          coverage_level: present(element(elements, 2)),
          amount: decimal_or_nil(elements[7]),
          percent: decimal_or_nil(elements[8]),
          in_network: in_network(elements[12])
        )
      end

      def service_type_codes(raw)
        codes = raw.to_s.split(@delimiters.fetch(:repetition)).map(&:strip).reject(&:empty?)
        codes.empty? ? [ nil ] : codes
      end

      # The plan name is EB05 on a coverage EB (EB01 1 or 6). EB04 is an
      # insurance type code. A copay, coinsurance, or other EB does not
      # supply a name. A later coverage EB replaces an earlier name.
      def remember_plan_name(plan_loop, elements, code)
        return unless coverage_status?(code)

        name = present(element(elements, 5))
        return if name.nil?

        plan_loop.plan_name = name
      end

      def coverage_status?(code)
        code == ACTIVE_COVERAGE_CODE || code == INACTIVE_COVERAGE_CODE
      end

      # Any AAA reject in the transaction — payer, provider, subscriber, or
      # dependent — means this is not a clean answer. AAA01 = N with no reason
      # code is still a reject.
      def consume_aaa(elements)
        code = element(elements, 3)
        valid_request = element(elements, 1).upcase
        return if code.empty? && valid_request != "N"

        @errors << EligibilityError.new(
          code: code.empty? ? "N" : code,
          description: reject_description(code),
          followup_action: present(element(elements, 4))
        )
      end

      def reject_description(code)
        return REJECTED_WITHOUT_REASON if code.empty?

        AAA_REJECT_REASONS.fetch(code, UNMAPPED_REJECT_DESCRIPTION)
      end

      def finish
        malformed! unless @transaction_271 && @closed
        refute_inverted_bounds!

        Result.new(
          plans: build_plans.freeze,
          errors: @errors.dup.freeze,
          raw_reference: raw_reference
        )
      end

      # A reversed plan window is malformed even when no benefit was read.
      # Ambiguous loops are not one patient, so only each loop's own bounds
      # are checked; the selected patient's combined bounds are checked
      # when the loops are not ambiguous.
      def refute_inverted_bounds!
        loops = patient_loops
        loops.each { |loop| malformed! if dates_reversed?(loop.coverage_start, loop.coverage_end) }
        one_eligibility_date(loops)
        return if ambiguous_loops?

        selected = selected_loop
        restrictive_pair(date_loops(selected)) if selected
      end

      def patient_loops
        @subscriber_loops + @dependent_loops
      end

      def build_plans
        return [] if ambiguous_loops?

        plan_loop = selected_loop
        return [] if plan_loop.nil? || plan_loop.benefits.empty?

        [ plan_from(plan_loop) ]
      end

      # Two information sources, two subscribers, or two dependents are
      # not one patient's answer. AAA segments are still reported.
      def ambiguous_loops?
        @subscriber_loops.length > 1 || @dependent_loops.length > 1 || @information_source_count > 1
      end

      # The dependent is the patient when a 23 loop is present. Otherwise
      # the single subscriber loop is.
      def selected_loop
        return @dependent_loops.first unless @dependent_loops.empty?

        @subscriber_loops.first
      end

      def plan_from(plan_loop)
        loops = date_loops(plan_loop)
        start_on, end_on, elig = coverage_bounds(loops)
        EligibilityPlan.new(
          payer_identifier: @payer_identifier,
          plan_name: plan_loop.plan_name,
          group_number: plan_loop.group_number,
          coverage_start: start_on,
          coverage_end: end_on,
          benefits: plan_loop.benefits,
          stated_windows: stated_windows_for(loops),
          eligibility_date: elig
        )
      end

      # Latest start and earliest end across the loops, then the eligibility
      # day when pinning it does not put the start after the end.
      def coverage_bounds(loops)
        start_on, end_on = restrictive_pair(loops)
        pin_eligibility_day(start_on, end_on, one_eligibility_date(loops))
      end

      def restrictive_pair(loops)
        start_on = loops.filter_map(&:coverage_start).max
        end_on = loops.filter_map(&:coverage_end).min
        malformed! if dates_reversed?(start_on, end_on)

        [ start_on, end_on ]
      end

      # Two different D8 307 days would pin the start to the later day and
      # the end to the earlier day. That window is malformed.
      def one_eligibility_date(loops)
        days = loops.filter_map(&:eligibility_date).uniq
        malformed! if days.size > 1

        days.first
      end

      # A lone eligibility day, or one that falls inside the other bounds,
      # pins both sides. A missing bound is open, so it contains the day.
      # A day outside the other bounds would invert the window; the plan
      # dates stay as they are and the day remains `eligibility_date`.
      def pin_eligibility_day(start_on, end_on, elig)
        return [ start_on, end_on, elig ] if elig.nil?

        pinned_start = later_date(start_on, elig)
        pinned_end = earlier_date(end_on, elig)
        return [ start_on, end_on, elig ] if dates_reversed?(pinned_start, pinned_end)

        [ pinned_start, pinned_end, elig ]
      end

      def later_date(bound, date)
        return date if bound.nil? || date > bound

        bound
      end

      def earlier_date(bound, date)
        return date if bound.nil? || date < bound

        bound
      end

      def stated_windows_for(loops)
        loops.filter_map(&:stated_window)
      end

      def date_loops(plan_loop)
        loops = []
        loops << @subscriber_loops.first if @dependent_loops.any?
        loops << plan_loop
        loops.compact.uniq
      end

      # ST02 is the transaction-set control number. It is not the member
      # identifier and not the fixture name.
      def raw_reference
        control = @st_control.to_s
        return nil if control.empty?

        "st:#{control}"
      end

      def element(elements, index)
        elements[index].to_s.strip
      end

      def present(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def decimal_or_nil(value)
        text = value.to_s.strip
        return nil if text.empty?

        amount = BigDecimal(text)
        amount.finite? ? amount : nil
      rescue ArgumentError
        nil
      end

      def in_network(value)
        case value.to_s.strip.upcase
        when "Y" then true
        when "N" then false
        end
      end

      def malformed!
        raise MalformedError, MALFORMED_MESSAGE, cause: nil
      end
    end
  end
end
