# frozen_string_literal: true

require "csv"
require "date"

module Corvid
  # Replaces one tenant's payer authorization rules from a CSV. A bad
  # cell or a failed save must not leave the tenant's previous rules
  # deleted. Messages name the row and, when known, the column only.
  class PayerAuthorizationRuleLoader
    class InvalidFile < StandardError; end

    HEADERS = %w[
      payer_identifier service_code code_from code_to place_of_service
      plan_identifier requirement effective_on expires_on
    ].freeze

    # strptime accepts 2025-1-1 for %Y-%m-%d. The shape check rejects that
    # before either parser runs; iso8601 also rejects it, and both reject
    # an impossible day such as 2025-02-30.
    DATE_SHAPE = /\A\d{4}-\d{2}-\d{2}\z/

    # First key of pg_advisory_xact_lock(int, int), via hashtext. The
    # tenant identifier is the second key, so one tenant's loads
    # serialize. hashtext can collide, so two tenants may occasionally
    # serialize, but a load never touches another tenant's rows.
    LOCK_NAMESPACE = "corvid_payer_authorization_rules"

    # Not one hierarchy. Errno::* is SystemCallError; IOError,
    # EncodingError, and a malformed CSV are not. Their messages quote
    # the source, so each becomes InvalidFile with that text dropped.
    SOURCE_ERRORS = [
      SystemCallError,
      IOError,
      EncodingError,
      CSV::MalformedCSVError
    ].freeze

    class << self
      def load!(path_or_io, tenant_identifier:)
        tenant = normalize_tenant(tenant_identifier)
        rows = parse(read_source(path_or_io))
        replace!(tenant, rows)
        rows.size
      end

      private

      def normalize_tenant(value)
        tenant = value.to_s.strip
        raise ArgumentError, "tenant_identifier is blank" if tenant.blank?

        tenant
      end

      def read_source(path_or_io)
        return read_io(path_or_io) if path_or_io.respond_to?(:read)

        read_file(path_or_io)
      end

      def read_io(io)
        io.read
      rescue *SOURCE_ERRORS
        unreadable_file!
      end

      def read_file(path)
        unreadable_file! unless File.file?(path)

        File.read(path)
      rescue *SOURCE_ERRORS
        unreadable_file!
      end

      def unreadable_file!
        raise InvalidFile, "file could not be read", cause: nil
      end

      def parse(content)
        header, *data = CSV.parse(content.to_s)
        raise InvalidFile, "header is invalid" unless header == HEADERS

        data_rows(data).each_with_index.map { |fields, index| build_fields(fields, index + 1) }
      rescue *SOURCE_ERRORS
        raise InvalidFile, "file is invalid", cause: nil
      end

      # CSV.parse turns a blank line into an empty field list. One at
      # the end is not a row. One between data rows is a short row.
      def data_rows(rows)
        last = rows.rindex { |fields| !fields.empty? }
        return [] if last.nil?

        rows[0..last]
      end

      def build_fields(fields, number)
        invalid!(number) unless fields.size == HEADERS.size

        build_row(CSV::Row.new(HEADERS, fields), number)
      end

      def build_row(row, number)
        codes = codes_for(row, number)
        attrs = {
          payer_identifier: required_text(row, "payer_identifier", number),
          service_code: codes[:service_code],
          code_from: codes[:code_from],
          code_to: codes[:code_to],
          place_of_service: optional_text(row, "place_of_service", number),
          plan_identifier: optional_text(row, "plan_identifier", number),
          requirement: requirement_for(row, number),
          effective_on: date_for(row, "effective_on", number, required: true),
          expires_on: date_for(row, "expires_on", number, required: false)
        }
        check_window!(attrs, number)
        attrs
      end

      def codes_for(row, number)
        service_code = code_cell(row, "service_code", number)
        code_from = code_cell(row, "code_from", number)
        code_to = code_cell(row, "code_to", number)
        check_code_form!(service_code, code_from, code_to, number)
        check_range!(code_from, code_to, number)
        { service_code: service_code, code_from: code_from, code_to: code_to }
      end

      def code_cell(row, column, number)
        text = cell_text(row, column, number)
        return nil if text.empty?

        normalized = PayerAuthorizationRule.normalize_code(text)
        return normalized if normalized

        invalid!(number, column)
      end

      def check_code_form!(service_code, code_from, code_to, number)
        exact = !service_code.nil?
        complete = !code_from.nil? && !code_to.nil?
        ranged = !code_from.nil? || !code_to.nil?
        return if exact && !ranged
        return if !exact && complete

        invalid!(number, "service_code")
      end

      def check_range!(code_from, code_to, number)
        return if code_from.nil? && code_to.nil?
        return if spanning_range?(code_from, code_to)

        invalid!(number, "code_from")
      end

      def spanning_range?(code_from, code_to)
        return false if code_from.nil? || code_to.nil?

        code_from.length == code_to.length &&
          code_from <= code_to &&
          PayerAuthorizationRule.same_code_pattern?(code_from, code_to)
      end

      # strip leaves U+00A0 and other characters Rails blank? rejects.
      # Collapse those to empty here so a row the loader accepts is not
      # refused at save for blankness. Optional blanks become NULL.
      def cell_text(row, column, number)
        text = scrubbed_cell(row[column])
        reject_control_character!(text, number, column)
        text
      end

      # A NUL makes the pg gem raise ArgumentError ("string contains
      # null byte") at save, which is not an ActiveRecord error. Other
      # controls are not identifiers either. Refuse them before any
      # write. Name the row and the column's place in the header so the
      # message does not repeat the cell.
      def reject_control_character!(text, number, column)
        return unless control_character?(text)

        invalid!(number, "column #{HEADERS.index(column) + 1}")
      end

      def scrubbed_cell(value)
        text = value.to_s.strip
        text.blank? ? "" : text
      rescue ArgumentError, EncodingError
        value.to_s
      end

      def control_character?(text)
        text.match?(/[[:cntrl:]]/)
      rescue ArgumentError, EncodingError
        true
      end

      def required_text(row, column, number)
        text = cell_text(row, column, number)
        return text if text.present?

        invalid!(number, column)
      end

      def optional_text(row, column, number)
        text = cell_text(row, column, number)
        text.empty? ? nil : text
      end

      def requirement_for(row, number)
        text = cell_text(row, "requirement", number)
        return text if PayerAuthorizationRule::REQUIREMENTS.include?(text)

        invalid!(number, "requirement")
      end

      def date_for(row, column, number, required:)
        text = cell_text(row, column, number)
        return nil if text.empty? && !required

        parsed = strict_date(text)
        return parsed if parsed

        invalid!(number, column)
      end

      def strict_date(text)
        return nil unless text.match?(DATE_SHAPE)

        parsed = Date.strptime(text, "%Y-%m-%d")
        iso = Date.iso8601(text)
        parsed if parsed == iso
      rescue Date::Error, ArgumentError
        nil
      end

      def check_window!(attrs, number)
        expires_on = attrs[:expires_on]
        return if expires_on.nil? || expires_on >= attrs[:effective_on]

        invalid!(number, "expires_on")
      end

      def invalid!(number, column = nil)
        message = column ? "row #{number}: #{column} is invalid" : "row #{number} is invalid"
        raise InvalidFile, message
      end

      # Delete and insert share one transaction. The advisory lock is
      # taken before the delete: under READ COMMITTED two loads can
      # otherwise interleave and both files' rows survive. The insert
      # is unscoped and names the tenant argument, so the thread tenant
      # cannot overwrite it. The delete is unscoped so another thread
      # tenant cannot spare this tenant's old rows.
      def replace!(tenant, rows)
        PayerAuthorizationRule.transaction(requires_new: true) do
          lock_tenant!(tenant)
          PayerAuthorizationRule.unscoped.where(tenant_identifier: tenant).delete_all
          insert_rows!(tenant, rows)
        end
      end

      def lock_tenant!(tenant)
        sql = PayerAuthorizationRule.sanitize_sql_array([
          "SELECT pg_advisory_xact_lock(hashtext(?), hashtext(?))",
          LOCK_NAMESPACE,
          tenant
        ])
        PayerAuthorizationRule.with_connection do |connection|
          result = connection.execute(sql, "Payer authorization rule load lock")
          result.clear if result.respond_to?(:clear)
        end
      end

      def insert_rows!(tenant, rows)
        rows.each_with_index do |attrs, index|
          create_row!(tenant, attrs, index + 1)
        end
      end

      # RecordInvalid, StatementInvalid, and any other ActiveRecord
      # error become InvalidFile. ArgumentError does too: a NUL the
      # cell check missed makes the pg gem raise it, and that is not
      # an ActiveRecord error. The column is not known on that path.
      # The exception propagates so the transaction rolls the delete
      # and the earlier inserts back.
      def create_row!(tenant, attrs, number)
        PayerAuthorizationRule.unscoped do
          PayerAuthorizationRule.create!(attrs.merge(tenant_identifier: tenant))
        end
      rescue ActiveRecord::ActiveRecordError => error
        invalid!(number, column_from(error))
      rescue ArgumentError
        invalid!(number)
      end

      def column_from(error)
        record = error.record if error.respond_to?(:record)
        return unless record.respond_to?(:errors)

        HEADERS.find { |name| record.errors[name].present? }
      end
    end
  end
end
