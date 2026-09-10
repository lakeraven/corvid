# frozen_string_literal: true

require "bigdecimal"
require "date"

require_relative "remittance"

module Corvid
  module Rcm
    # Minimal reader for the X12 835 Health Care Claim Payment/Advice.
    #
    # Deliberately narrow: it understands only the segments Phase 0 posts from
    # (BPR, TRN, DTM, N1, CLP, NM1, SVC, CAS, AMT) and ignores everything else
    # rather than guessing. It is a *fixture* reader — enough to derive real
    # structures from real 835 syntax so the posting logic is exercised against
    # the format it will meet in production, not a hand-built hash that quietly
    # agrees with the code under test. Production ingest of arbitrary payer 835s
    # (envelope validation, PLB provider-level adjustments, reversals, multiple
    # ST/SE transactions per file) is wave 2.
    #
    # Anything it cannot parse raises rather than returning a half-file:
    # silently dropping a CLP loop means silently losing money. That principle
    # is enforced twice here rather than left to the tests:
    #
    #   * a required monetary element that is absent is an ERROR, never a
    #     silent zero — a missing CLP04 posted as $0.00 is money that vanishes
    #     without anybody being told; and
    #   * the file has to BALANCE. BPR02 must equal the sum of CLP04 across the
    #     claim loops, so a file truncated mid-transmission cannot parse
    #     "successfully" with half its claims missing. Production files are the
    #     ones that will be malformed, so the guarantee belongs in the reader.
    class Edi835Reader
      class ParseError < StandardError; end

      SEGMENT_TERMINATOR = "~"
      ELEMENT_SEPARATOR = "*"
      COMPOSITE_SEPARATOR = ">"

      # DTM qualifiers used by the 835.
      DTM_PRODUCTION_DATE = "405"
      DTM_CLAIM_RECEIVED = "050"
      DTM_CLAIM_STATEMENT_START = "232"
      DTM_SERVICE_DATE = "472"

      def self.read(path)
        new(File.read(path)).parse
      end

      def initialize(source)
        @source = source.to_s
      end

      def parse
        segments = split_segments(@source)
        raise ParseError, "no segments found" if segments.empty?

        state = {
          remittance_identifier: nil, payer_name: nil, payee_identifier: nil,
          payment_method: nil, payment_amount: nil, payment_date: nil,
          currency: "USD", claims: []
        }
        claims = []
        current_claim = nil
        current_service = nil

        segments.each do |elements|
          case elements[0]
          when "BPR"
            # BPR02 monetary amount, BPR04 payment method, BPR16 payment date.
            # 005010X221A1 carries no currency element — USD by convention;
            # a non-USD tenant supplies it out of band.
            state[:payment_method] = elements[4]
            state[:payment_amount] = required_decimal(elements[2], "BPR02 payment amount")
            state[:payment_date] = parse_date(elements[16])
          when "TRN"
            state[:remittance_identifier] = elements[2]
          when "DTM"
            date = parse_date(elements[2])
            case elements[1]
            when DTM_PRODUCTION_DATE
              state[:payment_date] ||= date
            when DTM_SERVICE_DATE
              if current_service
                current_service[:serviced_date] = date
              elsif current_claim
                current_claim[:serviced_date] ||= date
              end
            when DTM_CLAIM_STATEMENT_START
              current_claim[:serviced_date] = date if current_claim
            end
          when "N1"
            case elements[1]
            when "PR" then state[:payer_name] = elements[2]
            when "PE" then state[:payee_identifier] = elements[4]
            end
          when "CLP"
            claims << finalize_claim(current_claim, current_service) if current_claim
            current_service = nil
            current_claim = {
              claim_identifier: elements[1],
              status_code: elements[2],
              billed_amount: required_decimal(elements[3], "CLP03 billed amount on claim #{elements[1].inspect}"),
              paid_amount: required_decimal(elements[4], "CLP04 paid amount on claim #{elements[1].inspect}"),
              # CLP05 is situational: absent means the patient owes nothing.
              patient_responsibility_amount: decimal(elements[5]),
              payer_control_number: elements[7],
              patient_identifier: nil,
              serviced_date: nil,
              adjustments: [],
              remark_codes: [],
              services: []
            }
          when "NM1"
            # QC = patient. The 835 carries the member id; Corvid holds no PHI,
            # so only the opaque member identifier is kept, never the name.
            if elements[1] == "QC" && current_claim
              current_claim[:patient_identifier] = elements[9]
            end
          when "SVC"
            raise ParseError, "SVC segment outside a CLP loop" unless current_claim

            current_claim[:services] << current_service if current_service
            code, *modifiers = elements[1].to_s.split(COMPOSITE_SEPARATOR)[1..] || []
            current_service = {
              procedure_code: code,
              modifiers: modifiers.reject { |m| m.to_s.empty? },
              billed_amount: required_decimal(elements[2], "SVC02 billed amount on #{code.inspect}"),
              paid_amount: required_decimal(elements[3], "SVC03 paid amount on #{code.inspect}"),
              units: elements[5].to_s.empty? ? 1 : elements[5].to_i,
              serviced_date: current_claim[:serviced_date],
              adjustments: [],
              remark_codes: []
            }
          when "CAS"
            adjustments = parse_cas(elements)
            target = current_service || current_claim
            raise ParseError, "CAS segment outside a CLP loop" unless target

            target[:adjustments].concat(adjustments)
          when "LQ"
            # LQ*HE*<RARC> — Health Care Remark Codes.
            next unless elements[1] == "HE" && !elements[2].to_s.empty?

            target = current_service || current_claim
            raise ParseError, "LQ segment outside a CLP loop" unless target

            target[:remark_codes] << elements[2]
          end
        end

        claims << finalize_claim(current_claim, current_service) if current_claim
        raise ParseError, "no CLP claim loops found" if claims.empty?

        remittance = Remittance.new(
          remittance_identifier: state[:remittance_identifier] || raise(ParseError, "missing TRN trace number"),
          payer_name: state[:payer_name],
          payee_identifier: state[:payee_identifier],
          payment_method: state[:payment_method],
          payment_amount: state[:payment_amount] || raise(ParseError, "missing BPR02 payment amount"),
          payment_date: state[:payment_date],
          currency: state[:currency],
          claims: claims
        )
        assert_balanced!(remittance)
        remittance
      end

      private

      # The 835 is a self-balancing document: the payment BPR02 actually made
      # is the sum of what was paid on each claim (CLP04). A file that does not
      # balance has lost claims — truncated in transit, mis-parsed here, or
      # carrying provider-level PLB adjustments this reader does not yet
      # understand. In every one of those cases the honest answer is to refuse
      # the file, not to post a total nobody can reconcile.
      def assert_balanced!(remittance)
        return if remittance.balanced?

        raise ParseError,
              "payment does not balance: BPR02 is #{remittance.payment_amount.to_s('F')} but the " \
              "#{remittance.claims.length} CLP loop(s) total #{remittance.claims_paid_total.to_s('F')}. " \
              "The file is truncated or carries provider-level (PLB) adjustments, which this reader does not support."
      end

      def split_segments(source)
        source.split(SEGMENT_TERMINATOR).filter_map do |raw|
          segment = raw.strip
          next if segment.empty?

          segment.split(ELEMENT_SEPARATOR, -1)
        end
      end

      # CAS01 is the group code, then up to six (reason, amount, quantity)
      # triplets in elements 2..19.
      def parse_cas(elements)
        group_code = elements[1]
        adjustments = []
        index = 2
        while index < elements.length
          reason = elements[index]
          break if reason.to_s.empty?

          adjustments << Adjustment.new(
            group_code: group_code,
            reason_code: reason,
            # CAS03 is required whenever CAS02 names a reason. An adjustment
            # with no amount is not a $0.00 adjustment, it is a broken segment.
            amount: required_decimal(elements[index + 1],
                                     "CAS amount for #{group_code}-#{reason}"),
            quantity: elements[index + 2].to_s.empty? ? nil : decimal(elements[index + 2])
          )
          index += 3
        end
        adjustments
      end

      def finalize_claim(claim, pending_service)
        claim[:services] << pending_service if pending_service
        services = claim[:services].map do |svc|
          RemittanceService.new(
            procedure_code: svc[:procedure_code],
            modifiers: svc[:modifiers],
            billed_amount: svc[:billed_amount],
            paid_amount: svc[:paid_amount],
            units: svc[:units],
            serviced_date: svc[:serviced_date] || claim[:serviced_date],
            adjustments: svc[:adjustments],
            remark_codes: svc[:remark_codes]
          )
        end

        RemittanceClaim.new(
          claim_identifier: claim[:claim_identifier],
          payer_control_number: claim[:payer_control_number],
          status_code: claim[:status_code],
          billed_amount: claim[:billed_amount],
          paid_amount: claim[:paid_amount],
          patient_responsibility_amount: claim[:patient_responsibility_amount],
          patient_identifier: claim[:patient_identifier],
          serviced_date: claim[:serviced_date],
          services: services,
          adjustments: claim[:adjustments],
          remark_codes: claim[:remark_codes]
        )
      end

      # For genuinely optional elements only. Everywhere a payer is obliged to
      # state an amount, use `required_decimal`: a missing amount defaulted to
      # zero is money that disappears without an error.
      def decimal(value)
        return BigDecimal(0) if value.nil? || value.to_s.strip.empty?

        BigDecimal(value.to_s.strip)
      rescue ArgumentError
        raise ParseError, "not a numeric value: #{value.inspect}"
      end

      def required_decimal(value, label)
        raise ParseError, "missing #{label}" if value.nil? || value.to_s.strip.empty?

        decimal(value)
      end

      def parse_date(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Date.strptime(value.to_s.strip, "%Y%m%d")
      rescue Date::Error
        raise ParseError, "not a CCYYMMDD date: #{value.inspect}"
      end
    end
  end
end
