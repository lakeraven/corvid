# frozen_string_literal: true

module Corvid
  # Parses RPMS PRC export files (caret-delimited records).
  #
  # Each line is a single record; the first field is the record type:
  #   H — header (file metadata)
  #   O — obligation (one PRC authorization)
  #   P — payment (one disbursement against an obligation)
  #   T — trailer (totals, used as integrity check)
  #
  # The parser is streaming-friendly — it reads line by line and yields
  # nothing in memory beyond the current record except in the final
  # `Report` aggregate that the caller asks for.
  module PrcReportParser
    Header = Struct.new(:type, :facility, :export_date, :version, keyword_init: true)
    Obligation = Struct.new(
      :obligation_id, :patient_dfn, :vendor_id,
      :procedure_code, :service_date, :status,
      :billed_amount, :paid_amount, :savings, :balance, :fiscal_year,
      keyword_init: true
    )
    Payment = Struct.new(
      :obligation_id, :payment_id, :paid_date, :check_number,
      :amount, :vendor_name,
      keyword_init: true
    )
    Trailer = Struct.new(
      :obligation_count, :patient_count, :payment_count,
      :total_paid, :total_outstanding,
      keyword_init: true
    )

    Report = Struct.new(:header, :obligations, :payments, :trailer, keyword_init: true)

    class << self
      def parse(io_or_string)
        io = io_or_string.respond_to?(:each_line) ? io_or_string : StringIO.new(io_or_string.to_s)
        report = Report.new(header: nil, obligations: [], payments: [], trailer: nil)

        io.each_line do |raw|
          line = raw.chomp
          next if line.empty?

          fields = line.split("^")
          case fields.first
          when "H"
            report.header = parse_header(fields)
          when "O"
            report.obligations << parse_obligation(fields)
          when "P"
            report.payments << parse_payment(fields)
          when "T"
            report.trailer = parse_trailer(fields)
          end
        end

        report
      end

      private

      def parse_header(f)
        Header.new(
          type: f[1],
          facility: f[2],
          export_date: parse_yyyymmdd(f[3]),
          version: f[4]
        )
      end

      def parse_obligation(f)
        Obligation.new(
          obligation_id: f[1],
          patient_dfn: f[2],
          vendor_id: f[3],
          procedure_code: f[4],
          service_date: parse_yyyymmdd(f[5]),
          status: f[6],
          billed_amount: f[7]&.to_d || 0.to_d,
          paid_amount: f[8]&.to_d || 0.to_d,
          savings: f[9]&.to_d || 0.to_d,
          balance: f[10]&.to_d || 0.to_d,
          fiscal_year: f[11]&.to_i
        )
      end

      def parse_payment(f)
        Payment.new(
          obligation_id: f[1],
          payment_id: f[2],
          paid_date: parse_yyyymmdd(f[3]),
          check_number: f[4],
          amount: f[5]&.to_d || 0.to_d,
          vendor_name: f[6]
        )
      end

      def parse_trailer(f)
        Trailer.new(
          obligation_count: f[1]&.to_i,
          patient_count: f[2]&.to_i,
          payment_count: f[3]&.to_i,
          total_paid: f[4]&.to_d || 0.to_d,
          total_outstanding: f[5]&.to_d || 0.to_d
        )
      end

      # YYYYMMDD → Date. Returns nil for empty/malformed.
      def parse_yyyymmdd(s)
        return nil if s.nil? || s.length < 8

        Date.new(s[0..3].to_i, s[4..5].to_i, s[6..7].to_i)
      rescue ArgumentError
        nil
      end
    end
  end
end
