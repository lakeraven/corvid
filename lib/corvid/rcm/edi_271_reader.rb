# frozen_string_literal: true

require "bigdecimal"

require_relative "eligibility"

module Corvid
  module Rcm
    # Minimal reader for the X12 271 Eligibility Benefit Response.
    #
    # It understands the segments a coverage answer is actually made of —
    # ISA delimiters, ST/SE, HL, NM1 (payer 2100A, subscriber 2100C), REF*6P,
    # DTP plan dates, EB, and AAA — and ignores the rest rather than guessing.
    # BHT is accepted and not mapped: BHT03 is a trace that can carry a
    # patient-control number, and `as_of` comes from the caller's clock, not
    # from the file. Demographic elements (NM103–NM107 names, DMG) are not
    # copied onto the result. The member identifier on NM109 is not copied
    # either: the caller already has it, and it must not reappear in a
    # reference or an exception (ADR 0003).
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

      # DTP01 qualifiers that carry the plan's coverage bounds.
      # 291 plan, 346/347 plan begin/end, 348/349 benefit begin/end,
      # 356/357 eligibility begin/end. RD8 is a range; D8 is one day.
      START_DATE_QUALIFIERS = %w[291 346 348 356].freeze
      END_DATE_QUALIFIERS = %w[347 349 357].freeze
      DATE_FORMAT = "D8"
      DATE_RANGE_FORMAT = "RD8"

      PAYER_ENTITY = "PR"
      PAYER_ID_QUALIFIER = "PI"
      INFORMATION_SOURCE_LEVEL = "20"
      GROUP_NUMBER_QUALIFIER = "6P"
      TRANSACTION_SET = "271"

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

      def utf8(source)
        text = source.to_s
        return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

        text.encode(Encoding::UTF_8)
      rescue EncodingError
        malformed!
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
        @benefits = []
        @errors = []
        @payer_identifier = nil
        @plan_name = nil
        @group_number = nil
        @coverage_start = nil
        @coverage_end = nil
        @coverage_start_seen = false
        @coverage_end_seen = false
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
      end

      # 2100A payer. NM109 is the payer identifier (PI). The organization name
      # in NM103 is not kept. Subscriber and dependent names are not read.
      def consume_nm1(elements)
        return unless element(elements, 1) == PAYER_ENTITY
        return unless element(elements, 8) == PAYER_ID_QUALIFIER
        return if @hl_level && @hl_level != INFORMATION_SOURCE_LEVEL

        identifier = element(elements, 9)
        return if identifier.empty?

        @payer_identifier ||= identifier
      end

      def consume_ref(elements)
        return unless element(elements, 1) == GROUP_NUMBER_QUALIFIER

        group = element(elements, 2)
        return if group.empty?

        @group_number ||= group
      end

      def consume_dtp(elements)
        format = element(elements, 2)
        raw = element(elements, 3)
        return if raw.empty?

        if format == DATE_RANGE_FORMAT
          apply_date_range(raw)
        elsif format == DATE_FORMAT
          apply_single_date(element(elements, 1), raw)
        end
      end

      def apply_date_range(raw)
        start_raw, end_raw = raw.split("-", 2)
        note_start(EligibilityPlan.coverage_date(start_raw))
        note_end(EligibilityPlan.coverage_date(end_raw)) unless end_raw.nil?
      end

      def apply_single_date(qualifier, raw)
        date = EligibilityPlan.coverage_date(raw)
        if END_DATE_QUALIFIERS.include?(qualifier)
          note_end(date)
        elsif START_DATE_QUALIFIERS.include?(qualifier)
          note_start(date)
        end
      end

      def note_start(date)
        return if @coverage_start_seen

        @coverage_start = date
        @coverage_start_seen = true
      end

      def note_end(date)
        return if @coverage_end_seen

        @coverage_end = date
        @coverage_end_seen = true
      end

      # EB03 repeats with the ISA repetition separator. One benefit per
      # service type code; a segment with none still counts toward outcome.
      def consume_eb(elements)
        code = element(elements, 1)
        malformed! if code.empty?

        remember_plan_name(elements, code)
        service_type_codes(element(elements, 3)).each do |service_type_code|
          @benefits << benefit(elements, code, service_type_code)
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

      # EB05 is the plan coverage description. EB04 (insurance type, or a plan
      # name when EB05 is empty) is the fallback. A later coverage EB (1 or 6)
      # replaces a name taken from a copay or coinsurance line.
      def remember_plan_name(elements, code)
        name = present(element(elements, 5)) || present(element(elements, 4))
        return if name.nil?
        return if @plan_name && !coverage_status?(code)

        @plan_name = name
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

        Result.new(
          plans: build_plans.freeze,
          errors: @errors.dup.freeze,
          raw_reference: raw_reference
        )
      end

      def build_plans
        return [] if @benefits.empty?

        [ EligibilityPlan.new(
          payer_identifier: @payer_identifier,
          plan_name: @plan_name,
          group_number: @group_number,
          coverage_start: @coverage_start,
          coverage_end: @coverage_end,
          benefits: @benefits
        ) ]
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
