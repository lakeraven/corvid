# frozen_string_literal: true

require "csv"

module Corvid
  # Outcomes for one tenant over a service-date range, grouped by payer,
  # facility, and the first day of the service month. Rejections and
  # denials are never combined into one figure.
  #
  # Per ADR 0002 every read runs inside that tenant's context and also
  # filters on tenant_identifier. Per ADR 0003 the read is ids, statuses,
  # dates, payer and facility identifiers, and denial reason codes only.
  #
  # `claims_sent`: claims in the group with submitted_at set.
  # `rejected_claims`: sent claims with rejected_at set.
  # `rejection_rate`: rejected_claims / claims_sent, a percentage rounded to one decimal, or 0.0 when none were sent.
  # `adjudicated_claims`: claims that are paid or were denied at least once.
  # `denied_claims`: adjudicated claims with denied_at set.
  # `denial_rate`: denied_claims / adjudicated_claims, a percentage rounded to one decimal, or 0.0 when none were adjudicated.
  # `outcome_claims`: claims that are paid, or that have rejected_at or denied_at set.
  # `first_pass_claims`: paid claims with neither rejected_at nor denied_at set.
  # `first_pass_rate`: first_pass_claims / outcome_claims, a percentage rounded to one decimal, or 0.0 when none have an outcome.
  # `finalized_claims`: claims whose status is paid, rejected, or denied.
  # `paid_claims`: claims whose status is paid.
  # `payment_rate`: paid_claims / finalized_claims, a percentage rounded to one decimal, or 0.0 when none are finalized.
  #
  # A denied claim counts once per distinct CARC category. A mapped code
  # uses its AdjustmentReasonCodes work queue. An unmapped code is
  # "unmapped". A denied claim with no codes is "uncoded".
  class ClaimOutcomeReport
    MEASURE_KEYS = %i[
      claims_sent rejected_claims rejection_rate adjudicated_claims denied_claims denial_rate
      outcome_claims first_pass_claims first_pass_rate finalized_claims paid_claims payment_rate
    ].freeze

    COUNT_KEYS = MEASURE_KEYS.reject { |key| key.end_with?("_rate") }.freeze

    # Numerators and denominators of the four rates. Counts use the same
    # predicates as ClaimSubmission.rejection_rate, #denial_rate,
    # #first_pass_rate, and #payment_rate.
    RATE_NUMERATOR = {
      rejection_rate: :rejected_claims,
      denial_rate: :denied_claims,
      first_pass_rate: :first_pass_claims,
      payment_rate: :paid_claims
    }.freeze

    RATE_DENOMINATOR = {
      rejection_rate: :claims_sent,
      denial_rate: :adjudicated_claims,
      first_pass_rate: :outcome_claims,
      payment_rate: :finalized_claims
    }.freeze

    # Allowlist. Patient identifiers, token columns, and amounts are absent.
    READ_COLUMNS = %i[
      id
      payer_identifier
      facility_identifier
      service_date
      status
      submitted_at
      rejected_at
      denied_at
      denial_reason_codes
    ].freeze

    PREDICATES = {
      claims_sent: :sent?,
      rejected_claims: :rejected?,
      adjudicated_claims: :adjudicated?,
      denied_claims: :denied?,
      outcome_claims: :outcome?,
      first_pass_claims: :first_pass?,
      finalized_claims: :finalized?,
      paid_claims: :paid?
    }.freeze

    # One plucked claim. No patient identifier, token, or amount.
    Snapshot = Data.define(*READ_COLUMNS) do
      FINAL_STATUSES = %w[paid rejected denied].freeze

      def sent?
        !submitted_at.nil?
      end

      def rejected?
        sent? && !rejected_at.nil?
      end

      def denied?
        !denied_at.nil?
      end

      def adjudicated?
        paid? || denied?
      end

      def outcome?
        paid? || !rejected_at.nil? || !denied_at.nil?
      end

      def first_pass?
        paid? && rejected_at.nil? && denied_at.nil?
      end

      def finalized?
        FINAL_STATUSES.include?(status)
      end

      def paid?
        status == "paid"
      end
    end
    private_constant :Snapshot

    class Row
      EMPTY_IDS = [].freeze

      attr_reader :payer_identifier, :facility_identifier, :month, :measures, :denials_by_category

      MEASURE_KEYS.each do |key|
        define_method(key) { measures.fetch(key) }
      end

      def initialize(payer_identifier:, facility_identifier:, month:, claims:)
        @payer_identifier = payer_identifier
        @facility_identifier = facility_identifier
        @month = month
        @ids_by_measure = measure_ids(claims)
        @ids_by_category = category_ids(claims)
        @measures = build_measures
        @denials_by_category = @ids_by_category.transform_values(&:size).freeze
        freeze
      end

      def claim_ids(measure)
        @ids_by_measure.fetch(count_measure(measure))
      end

      def denominator_ids(measure)
        key = RATE_DENOMINATOR[measure]
        raise ArgumentError, "unknown measure" unless key

        @ids_by_measure.fetch(key)
      end

      def claim_ids_for_denial_category(category)
        @ids_by_category.fetch(category) { EMPTY_IDS }
      end

      private

      def count_measure(measure)
        return measure if @ids_by_measure.key?(measure)

        numerator = RATE_NUMERATOR[measure]
        return numerator if numerator

        raise ArgumentError, "unknown measure"
      end

      def measure_ids(claims)
        buckets = COUNT_KEYS.index_with { [] }
        claims.each { |claim| tally_measures(buckets, claim) }
        buckets.transform_values { |ids| ids.sort.freeze }.freeze
      end

      def tally_measures(buckets, claim)
        COUNT_KEYS.each do |key|
          buckets[key] << claim.id if claim.public_send(PREDICATES.fetch(key))
        end
      end

      def build_measures
        MEASURE_KEYS.index_with { |key| value_for(key) }.freeze
      end

      def value_for(key)
        return count_of(key) unless RATE_NUMERATOR.key?(key)

        percentage(count_of(RATE_NUMERATOR[key]), count_of(RATE_DENOMINATOR[key]))
      end

      def count_of(key)
        @ids_by_measure.fetch(key).size
      end

      # ClaimSubmission.percentage: one decimal, 0.0 when the denominator is empty.
      def percentage(count, total)
        return 0.0 if total == 0

        (count.to_f / total * 100).round(1)
      end

      def category_ids(claims)
        buckets = Hash.new { |hash, key| hash[key] = [] }
        claims.each do |claim|
          categories_for(claim).each { |category| buckets[category] << claim.id }
        end
        buckets.sort.to_h.transform_values { |ids| ids.uniq.sort.freeze }.freeze
      end

      def categories_for(claim)
        return [] unless claim.denied?

        codes = present_codes(claim.denial_reason_codes)
        return [ "uncoded" ] if codes.empty?

        codes.map { |code| category_for(code) }.uniq
      end

      def present_codes(codes)
        Array(codes).map { |code| code.to_s.strip }.reject(&:empty?)
      end

      def category_for(code)
        classified = Corvid::Rcm::AdjustmentReasonCodes.default.classify(code)
        return "unmapped" unless classified.mapped?

        classified.work_queue.to_s
      end
    end

    def initialize(tenant_identifier:, date_range:, facility_identifier: nil, payer_identifier: nil)
      @tenant_identifier = validate_tenant!(tenant_identifier)
      @date_range = validate_date_range!(date_range)
      @facility_identifier = facility_identifier
      @payer_identifier = payer_identifier
    end

    def rows
      @rows ||= build_rows.freeze
    end

    def to_csv
      categories = category_columns
      CSV.generate do |csv|
        csv << csv_headers(categories)
        rows.each { |row| csv << csv_values(row, categories) }
      end
    end

    private

    attr_reader :tenant_identifier, :date_range, :facility_identifier, :payer_identifier

    def validate_tenant!(identifier)
      return identifier if identifier.is_a?(String) && !identifier.strip.empty?

      raise ArgumentError, "tenant_identifier must be a non-blank string"
    end

    def validate_date_range!(range)
      return range if range_of_dates?(range)

      raise ArgumentError, "date_range must be a Range of Dates"
    end

    def range_of_dates?(range)
      range.is_a?(Range) && range.begin.instance_of?(Date) && range.end.instance_of?(Date)
    end

    def build_rows
      grouped = load_snapshots.group_by { |claim| group_key(claim) }
      grouped.keys.sort_by { |key| sort_key(key) }.map { |key| build_row(key, grouped.fetch(key)) }
    end

    def group_key(claim)
      [ claim.payer_identifier, claim.facility_identifier, claim.service_date.beginning_of_month ]
    end

    def sort_key(key)
      payer, facility, month = key
      [ month, nil_rank(payer), payer.to_s, nil_rank(facility), facility.to_s ]
    end

    def nil_rank(value)
      value.nil? ? 0 : 1
    end

    def build_row(key, claims)
      payer, facility, month = key
      Row.new(payer_identifier: payer, facility_identifier: facility, month: month, claims: claims)
    end

    # Load inside the tenant block. with_tenant restores the caller's
    # context, including when it was unset. Pluck runs here so a relation
    # never escapes the block. The explicit tenant filter holds if the
    # default scope changes.
    def load_snapshots
      Corvid::TenantContext.with_tenant(tenant_identifier) do
        plucked = Corvid::ClaimSubmission.where(query_filters).pluck(*READ_COLUMNS)
        plucked.map { |values| Snapshot.new(*values) }
      end
    end

    def query_filters
      filters = { tenant_identifier: tenant_identifier, service_date: date_range }
      filters[:facility_identifier] = facility_identifier unless facility_identifier.nil?
      filters[:payer_identifier] = payer_identifier unless payer_identifier.nil?
      filters
    end

    def category_columns
      rows.flat_map { |row| row.denials_by_category.keys }.uniq.sort
    end

    def csv_headers(categories)
      [
        "payer_identifier",
        "facility_identifier",
        "month",
        *MEASURE_KEYS.map(&:to_s),
        *categories.map { |category| "denials_#{category}" }
      ]
    end

    def csv_values(row, categories)
      [
        row.payer_identifier,
        row.facility_identifier,
        row.month.strftime("%Y-%m"),
        *MEASURE_KEYS.map { |key| row.measures.fetch(key) },
        *categories.map { |category| row.denials_by_category.fetch(category, 0) }
      ]
    end
  end
end
