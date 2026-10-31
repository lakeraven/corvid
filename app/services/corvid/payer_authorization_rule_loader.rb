# frozen_string_literal: true

require "csv"
require "date"

module Corvid
  # Replaces one tenant's payer authorization rules from a CSV. Every row
  # is validated before any write: a bad cell must not delete the rules
  # already in force. Messages name the row and column only.
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
        raise ArgumentError, "tenant_identifier is blank" if tenant.empty?

        tenant
      end

      def read_source(path_or_io)
        return path_or_io.read if path_or_io.respond_to?(:read)

        File.read(path_or_io)
      end

      def parse(content)
        table = CSV.parse(content.to_s, headers: true)
        raise InvalidFile, "header is invalid" unless table.headers == HEADERS

        table.each_with_index.map { |row, index| build_row(row, index + 1) }
      rescue CSV::MalformedCSVError
        raise InvalidFile, "file is invalid"
      end

      def build_row(row, number)
        codes = codes_for(row, number)
        attrs = {
          payer_identifier: required_text(row, "payer_identifier", number),
          service_code: codes[:service_code],
          code_from: codes[:code_from],
          code_to: codes[:code_to],
          place_of_service: optional_text(row, "place_of_service"),
          plan_identifier: optional_text(row, "plan_identifier"),
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
        text = row[column].to_s.strip.upcase
        return nil if text.empty?
        return text if text.match?(PayerAuthorizationRule::CODE_FORMAT)

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
        return if code_from && code_to && code_from.length == code_to.length && code_from <= code_to

        invalid!(number, "code_from")
      end

      def required_text(row, column, number)
        text = row[column].to_s.strip
        return text if text.present?

        invalid!(number, column)
      end

      def optional_text(row, column)
        text = row[column].to_s.strip
        text.empty? ? nil : text
      end

      def requirement_for(row, number)
        text = row["requirement"].to_s.strip
        return text if PayerAuthorizationRule::REQUIREMENTS.include?(text)

        invalid!(number, "requirement")
      end

      def date_for(row, column, number, required:)
        text = row[column].to_s.strip
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

      def invalid!(number, column)
        raise InvalidFile, "row #{number}: #{column} is invalid"
      end

      # Delete and insert share one transaction. create! runs inside the
      # named tenant; the delete is unscoped so another thread tenant
      # cannot spare this tenant's old rows.
      def replace!(tenant, rows)
        PayerAuthorizationRule.transaction(requires_new: true) do
          PayerAuthorizationRule.unscoped.where(tenant_identifier: tenant).delete_all
          Corvid::TenantContext.with_tenant(tenant) do
            rows.each do |attrs|
              PayerAuthorizationRule.create!(attrs.merge(tenant_identifier: tenant))
            end
          end
        end
      end
    end
  end
end
